#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
LingoFuse HTTP Bridge - Bidirectional HTTP <-> LingoFuse POST gateway
with canonical JSON normalization.

This module provides a single-process, stateless bridge that operates
in BOTH directions:

  Direction A (inbound, HTTP -> LingoFuse):
      The bridge listens on an HTTP port. A client POSTs to
      /<app_name>/<api_name>; the bridge forwards the body to the
      LingoFuse App named <app_name> by calling <api_name>, then
      returns the LingoFuse response as the HTTP response.

  Direction B (outbound, LingoFuse -> HTTP):
      The bridge registers its own LingoFuse App and exposes a Call
      API (by default named "__lf_outbound_post__"). A LingoFuse
      client can call this API with a JSON request describing an
      outbound HTTP POST; the bridge performs the POST and returns
      the HTTP response as a JSON object.

  Direction C (repair, LingoFuse -> LingoFuse):
      The bridge registers a SECOND Call API on the same App (by
      default named "__lf_repair_json__"). A LingoFuse client can
      call this API with a malformed JSON string; the bridge runs
      the unified repair engine (lingofuse.json_repair_preprocess)
      on the text and returns the repaired text as a plain string.
      The input and output are both UTF-8, NUL-terminated, and the
      output NEVER contains a \\uXXXX escape for any character that
      can be emitted literally in UTF-8.

With all three directions active, this bridge is a universal
LingoFuse gateway: HTTP clients can reach LingoFuse services,
LingoFuse clients can reach external HTTP services, and any
LingoFuse client can delegate JSON repair to the bridge.

==================== FORWARD-ONLY MODE ====================
The bridge supports a dedicated FORWARD-ONLY operating mode that
completely disables the HTTP listener. In this mode:

    * No Flask application is started.
    * No TCP port is opened.
    * Only the LingoFuse Call APIs are registered and served:
        - the outbound HTTP POST proxy (Direction B), and
        - the JSON repair service (Direction C).

This is useful when:
    * The bridge runs as a sidecar / internal node that should NOT
      be reachable over the network, but still needs to provide
      outbound HTTP proxying and JSON repair to LingoFuse peers.
    * The HTTP listener is handled by a different process or a
      reverse proxy, and this instance is dedicated to Call API
      serving.
    * Port binding is restricted by the host environment.

The mode is controlled by the `forward_only` field of the global
`BridgeConfig` instance, and can be set through any of the three
standard layers (global variable, environment variable, command
line). See the "CONFIGURATION MODEL" section below.

When forward-only mode is active, the main Python thread simply
waits (sleeping) while the LingoFuse worker threads service the
registered APIs. The process exits on Ctrl+C (KeyboardInterrupt)
or SIGTERM, and the standard `cleanup()` path runs on exit.

==================== CONFIGURATION MODEL ====================
All runtime configuration lives in a single BridgeConfig instance
(the module-level `config` object). The configuration is populated
EXACTLY ONCE at process startup, in two phases:

    Phase 1 - environment variables (`_apply_environment_defaults`)
    Phase 2 - command-line arguments (`_apply_command_line`)

Command-line arguments override environment variables, which override
the built-in defaults. After startup, no code path in this module
reads os.environ or sys.argv directly. Every consumer -- including
the per-request hot path and the LingoFuse callbacks -- reads the
global `config` instance. This eliminates the class of bugs where a
hot path observes a runtime-mutated environment.

A third entry point is available for embedded / programmatic use:
since `config` is a plain module-level object, code that imports
this module may assign to any of its fields BEFORE `main()` runs.
`main()` does NOT overwrite a field that the caller has already
populated... unless the environment variable or command-line flag
explicitly targets that field. This lets an embedding application
pin, for example, `config.forward_only = True` and still allow
downstream operators to override it via environment / CLI if they
so choose.

==================== WHY JSON NORMALIZATION ====================
A backend service usually expects canonical UTF-8 JSON. A browser or
a third-party client, however, may send any of the following:

    * A payload encoded as GBK / Latin-1 instead of UTF-8.
    * A payload prefixed with a UTF-8 BOM (EF BB BF).
    * A payload with a trailing NUL byte (0x00) left over from a
      Pascal LF_WriteString call.
    * A payload with a trailing comma before a closing brace or
      bracket (JSON5-style, not accepted by strict parsers).
    * A payload that escapes every non-ASCII character as \\uXXXX.
    * A payload that is malformed in more aggressive ways, such as
      missing quotes, single-quoted strings, or unbalanced braces.

Any of these can break a strict backend JSON parser. The bridge
normalizes them into canonical UTF-8 JSON with literal non-ASCII
characters. The operation is idempotent for already-canonical input.

The canonical policy is defined ONCE, by lingofuse.lf_io.dumps_json:

    json.dumps(obj, ensure_ascii=False, default=str)

EVERY JSON string produced by this module -- whether for an inbound
LingoFuse call, an outbound HTTP request body, an HTTP response
body, or a repair-API response -- passes through that function (or
through the repair engine invoked with ensure_ascii=False). This
guarantees that no \\uXXXX escape ever appears on any wire, in any
direction.

==================== UNIFIED JSON REPAIR PREPROCESSING ====================
The bridge's inbound path operates on raw bytes and therefore does
NOT go through lingofuse.lf_io.read_json or
lingofuse.serializers.default_deserializer. To keep the repair
coverage symmetric across the toolchain, the bridge applies the
unified repair preprocessor itself, inside normalize_json_bytes().

The repair stack has TWO layers, applied in order of increasing
aggressiveness:

    Layer 1: `_try_repair_json()`, defined in this module. A small
             set of SAFE, conservative repairs (strip a stray Unicode
             BOM character, remove trailing commas before a closing
             brace or bracket). These never change the meaning of a
             well-formed document.

    Layer 2: `lingofuse.json_repair_preprocess.repair_json_text`.
             The unified engine used by every other JSON read path in
             the toolchain (lf_io.read_json, lf_io.read_json_or_bytes,
             serializers.default_deserializer). More aggressive, but
             it re-validates its own output against strict JSON, so
             the bridge's binary-safety guarantee is preserved: any
             payload that still fails strict parsing after both
             layers is returned UNCHANGED with STATUS_PASSTHROUGH.

Layer 2 is called with `report_failure=False`. This is deliberate:
for the bridge, a non-JSON payload is NOT an error, it is a valid
"passthrough" outcome (see BINARY SAFETY below). The unified engine
still emits a WARNING when a repair succeeds, which is the signal
the operator wants to see; it simply does not emit an ERROR when the
payload turns out to be binary data that it should leave alone.

Layer 2 can be disabled globally with the environment variable
LINGOFUSE_JSON_REPAIR=0. In that case, only Layer 1 remains active,
and the bridge behaves exactly as it did before the unified repair
was introduced.

==================== REPAIR API (DIRECTION C) ====================
The `__lf_repair_json__` Call API is the entry point that lets a
LingoFuse caller delegate JSON repair to the bridge. Its contract:

    Input  (DataHandle): UTF-8 encoded JSON text. May or may not be
                         NUL-terminated; may be malformed.
    Output (DataHandle): UTF-8 encoded text, NUL-terminated. Contains
                         either the repaired JSON, or the original
                         input when no repair was possible.

Behaviour:

    * The input bytes are stripped of a UTF-8 BOM and trailing NULs,
      then decoded with the same encoding fallback chain used by
      normalize_json_bytes(): UTF-8 -> GBK -> Latin-1.

    * The decoded text is passed to repair_json_text() with
      report_failure=True. The engine is invoked with
      ensure_ascii=False, so the returned text NEVER contains a
      \\uXXXX escape for a character that can be emitted literally.

    * If the input is already valid JSON, the text is returned
      unchanged (no log message).

    * If the input is malformed but repairable, the repaired text
      is returned (one WARNING is logged).

    * If the input cannot be repaired, the original text is returned
      (one ERROR is logged). This mirrors the binary-safety policy
      of the inbound path: the bridge never silently corrupts a
      payload.

    * If the input bytes cannot be decoded as text at all, the raw
      bytes are returned unchanged, matching the passthrough
      semantics of normalize_json_bytes().

    * Exceptions raised anywhere in the callback are caught and
      converted into an empty output. No exception is allowed to
      escape into the C stack.

==================== BINARY SAFETY ====================
The bridge is a generic passthrough, not only for JSON. On the
inbound path, if a payload cannot be interpreted as JSON (for
example, an image or a custom binary protocol), the original bytes
are forwarded UNCHANGED. The bridge NEVER silently corrupts a binary
payload.

On the outbound path, the request body is always JSON by contract
(the LingoFuse caller sends a JSON request object). The HTTP
response body is inspected: if it parses as JSON it is embedded as a
JSON value, otherwise it is embedded as a raw string. No
payload corruption occurs either way.

On the repair path, the same policy applies: an undecodable payload
is returned unchanged, and an unrepairable payload is returned
unchanged.

==================== UNICODE ENCODING SAFETY (G2 fix) ====================
Every Python-string-to-UTF-8-bytes conversion in this module now uses
`errors="replace"`. Rationale:

  * dumps_json (with ensure_ascii=False) preserves any Unicode scalar
    that the object graph contains, including lone surrogates if a
    non-conformant producer injected one (this can happen when a
    remote server returns a JSON string containing a literal "\\udXXX"
    escape that json.loads decodes into a Python surrogate).

  * A Python str that contains a lone surrogate CANNOT be encoded to
    valid UTF-8. Without `errors="replace"`, `.encode("utf-8")` would
    raise UnicodeEncodeError and abort the whole request.

  * With `errors="replace"`, the lone surrogate is emitted as U+FFFD
    (the Unicode replacement character). The JSON is still valid,
    still UTF-8, still round-trippable, and no exception is raised.

This is a defensive fix. In practice a well-formed peer never sends
lone surrogates; the fix exists so that a broken peer cannot bring
the bridge down.

==================== INBOUND REQUEST FORMAT ====================
POST /<app_name>/<api_name>
Content-Type: any (ignored by bridge, preserved for backend)
Body: arbitrary binary data (JSON is normalized)

If only one path segment is given (e.g. /api_name), the default app
(specified via --app or LINGOFUSE_APP) is used.

==================== INBOUND RESPONSE FORMAT ====================
Success: HTTP 200 with the (possibly normalized) response body.
Failure (bridge-level errors):
    {"code": -1, "error": "..."}     # call error (timeout, etc.)
    {"code": -2, "error": "..."}     # request shape error (HTTP 400)
    {"code": -3, "error": "..."}     # check_api pre-check failed

==================== OUTBOUND LINGOFUSE CALL API ====================
The bridge registers a Call API on its own LingoFuse App. By default:

    App name:  __lf_http_bridge__
    POST API:  __lf_outbound_post__
    Repair API: __lf_repair_json__

All names use a double-underscore prefix and suffix. This is a
deliberate namespace convention: the double-underscore marker cannot
appear in a normal HTTP URL path without encoding, so the bridge's
own APIs can NEVER collide with a business API routed through the
inbound direction. Callers who need to override any of these names
can use --bridge-app / --bridge-api / --bridge-repair-api or
LINGOFUSE_BRIDGE_APP / LINGOFUSE_BRIDGE_API /
LINGOFUSE_BRIDGE_REPAIR_API.

Outbound POST request JSON (from the LingoFuse caller):

    {
        "url":     "http://example.com/api",   # required
        "method":  "POST",                     # optional, default POST
        "headers": { "X-Foo": "Bar" },         # optional
        "body":    { "any": "json" },          # optional, JSON only
        "timeout": 10                          # optional, seconds
    }

The body field is re-serialized through dumps_json before being sent
to the remote HTTP server, so the wire form is always canonical
UTF-8 with literal non-ASCII characters.

Outbound POST response JSON (returned to the LingoFuse caller):

    {
        "status_code": 200,
        "headers":     { "content-type": "application/json", ... },
        "body":        { ... } | "raw string if not JSON"
    }

On error:

    { "error": "description of the failure" }

Repair request (from the LingoFuse caller):

    Any UTF-8 JSON text, including malformed JSON.

Repair response (returned to the LingoFuse caller):

    The repaired UTF-8 JSON text, or the original text when repair
    was not possible. The response is a plain string payload, NOT a
    JSON object.

==================== THREADING ====================
The HTTP server may run with threaded=True (the default), so
handle_call() runs on multiple Flask worker threads concurrently.
The LingoFuse callbacks (_bridge_post_callback and
_bridge_repair_callback) run on LingoFuse's own worker threads,
independently of Flask.

In forward-only mode, there is no Flask thread pool at all: only the
LingoFuse worker threads execute the Call APIs, and the main Python
thread simply sleeps until the process is asked to exit.

Safe shared state:
    * `config`        : frozen after startup, read-only.
    * `logger`        : thread-safe by design.
    * `requests`      : top-level request() creates a fresh
                        connection per call, no shared mutable state.
    * `_bridge_app_*` : written once during _setup_network() before
                        the HTTP server starts, then only read.

No additional locking is required.

==================== DEPENDENCIES ====================
- lingofuse package (must be on PYTHONPATH)
- Flask (only required when forward-only mode is DISABLED)
- requests

All comments and log messages are in English.
"""

import argparse
import atexit
import codecs
import json
import logging
import os
import re
import sys
import time
from dataclasses import dataclass
from typing import Optional, Tuple

import requests
from flask import Flask, request, Response

# Make sibling modules importable when the script is run directly.
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from lingofuse import set_option, check_api, get_status, get_status_num
from lingofuse.errors import ConnectionError, TimeoutError, LingoFuseError
from lingofuse._lf_native import (
    LF_ResetPrepare,
    LF_PrepareClient,
    LF_PrepareDone,
    LF_Call,
    LF_FreeData,
    LF_CreateData,
    LF_ExitMainThread,
    LF_Shutdown,
    LF_CreateApp,
    LF_FreeApp,
    LF_RegisterCall,
    LFCallFunc,
)
from lingofuse.core import DataHandle

# ----------------------------------------------------------------------
# Unified LingoFuse payload I/O.
#
# Every NUL framing operation, every c_char_p parameter, and every
# JSON serialization/deserialization in this file goes through
# lingofuse.lf_io, the single source of truth for the toolchain's
# wire format policy.
#
# The bridge relies on the following lf_io primitives:
#
#   cstr               NUL-terminated UTF-8 bytes for c_char_p args.
#   dumps_json         Canonical JSON serialization policy.
#   write_string_bytes Write raw bytes + NUL to a DataHandle.
#   read_string_bytes  Read up to the first NUL (or the whole buffer).
#   ENCODING           The only encoding used on the wire ("utf-8").
# ----------------------------------------------------------------------
from lingofuse.lf_io import (
    ENCODING,
    cstr,
    dumps_json,
    read_string_bytes,
    write_string_bytes,
)

# ----------------------------------------------------------------------
# Unified JSON repair preprocessing.
#
# normalize_json_bytes() applies this engine as Layer 2 of its repair
# stack, after the bridge's own conservative repairs (Layer 1). See
# the module docstring section "UNIFIED JSON REPAIR PREPROCESSING"
# for the full rationale.
#
# The repair Call API (_bridge_repair_callback) also uses this engine
# directly. The engine is invoked with ensure_ascii=False internally,
# so the repaired text never contains a \uXXXX escape for a character
# that can be emitted literally in UTF-8.
#
# The import is intentionally unconditional at module level. The
# preprocessor degrades gracefully at first use if the vendored
# lingofuse.json_repair subpackage is unavailable, so a missing
# engine never prevents the bridge from starting.
# ----------------------------------------------------------------------
from lingofuse.json_repair_preprocess import repair_json_text


# ======================================================================
# Defaults
# ======================================================================
#
# These values are the ultimate fallback. They are used only by
# `_apply_environment_defaults()`, which is called exactly once at
# startup. No hot-path code reads these constants directly.
#
# The bridge App / API names use a double-underscore prefix and
# suffix. This is a namespace convention: the double-underscore marker
# cannot appear in a normal HTTP URL path without encoding, so the
# bridge's own LingoFuse APIs can never collide with a business API
# routed through the inbound direction. See the module docstring.
# ======================================================================

DEFAULT_HOST = '0.0.0.0'
DEFAULT_PORT = 8081
DEFAULT_ENDPOINT = 'ipc:lingofuse_bridge'
DEFAULT_TIMEOUT_MS = 5000
DEFAULT_THREADED = True
DEFAULT_DEBUG = False
DEFAULT_NO_PRECHECK = False
DEFAULT_NORMALIZE_JSON = True
DEFAULT_LOG_FILE = None
DEFAULT_BRIDGE_APP_NAME = '__lf_http_bridge__'
DEFAULT_BRIDGE_API_NAME = '__lf_outbound_post__'
DEFAULT_BRIDGE_REPAIR_API_NAME = '__lf_repair_json__'

#: When True, the HTTP listener is COMPLETELY DISABLED and the bridge
#: only serves its LingoFuse Call APIs (outbound POST proxy and JSON
#: repair). See the "FORWARD-ONLY MODE" section in the module
#: docstring for the full rationale.
DEFAULT_FORWARD_ONLY = False

#: The lower-case HTTP methods the outbound proxy is willing to
#: forward. Anything else is rejected before the request is built.
#: This is a security / correctness guard, not a business policy.
ALLOWED_HTTP_METHODS = frozenset(
    ('GET', 'POST', 'PUT', 'PATCH', 'DELETE', 'HEAD', 'OPTIONS')
)

#: Upper bound on the outbound HTTP timeout, in seconds. Anything
#: larger is clamped, to protect the bridge from a mis-configured
#: caller that would otherwise hold a worker thread indefinitely.
MAX_OUTBOUND_TIMEOUT_S = 300.0


# ======================================================================
# BridgeConfig - the single source of runtime configuration
# ======================================================================
#
# This dataclass instance is the one and only place where the running
# configuration lives. It is populated exactly once, by `main()`, and
# is read-only for the rest of the process lifetime.
#
# A note on thread safety: after `main()` finishes populating the
# instance, no field is ever written again. Concurrent reads from
# Flask worker threads and LingoFuse callback threads are therefore
# safe without any lock.
#
# A note on embedded / programmatic use: because `config` is a plain
# module-level object, code that imports this module may assign to
# any of its fields BEFORE `main()` runs. This is the "global
# variable" layer of the three-layer configuration mechanism
# (global variable / environment variable / command line).
# ======================================================================

@dataclass
class BridgeConfig:
    """The process-wide, immutable-after-startup configuration."""

    # --- inbound HTTP server ---
    host: str = DEFAULT_HOST
    port: int = DEFAULT_PORT
    threaded: bool = DEFAULT_THREADED

    # --- operating mode ---
    # When True, the HTTP listener is disabled. Only the LingoFuse
    # Call APIs are registered and served.
    forward_only: bool = DEFAULT_FORWARD_ONLY

    # --- LingoFuse connection ---
    endpoint: str = DEFAULT_ENDPOINT
    timeout_ms: int = DEFAULT_TIMEOUT_MS
    default_app: Optional[str] = None
    no_precheck: bool = DEFAULT_NO_PRECHECK

    # --- payload handling ---
    normalize_json: bool = DEFAULT_NORMALIZE_JSON

    # --- diagnostics ---
    debug: bool = DEFAULT_DEBUG
    log_file: Optional[str] = DEFAULT_LOG_FILE

    # --- outbound LingoFuse Call API registration ---
    bridge_app_name: str = DEFAULT_BRIDGE_APP_NAME
    bridge_api_name: str = DEFAULT_BRIDGE_API_NAME
    bridge_repair_api_name: str = DEFAULT_BRIDGE_REPAIR_API_NAME


# The process-wide configuration instance. Populated once by main().
config = BridgeConfig()


# ======================================================================
# Environment-variable table
# ----------------------------------------------------------------------
# Maps each configuration field to the environment variable that
# provides its default. This table is the ONLY place in the module
# that knows about environment variable names.
#
# The entries are read by `_apply_environment_defaults()`, which is
# called exactly once, from `main()`. No other code path touches
# `os.environ`.
# ======================================================================

_ENV_VAR_TABLE = {
    'host':                    'LINGOFUSE_HOST',
    'port':                    'LINGOFUSE_PORT',
    'endpoint':                'LINGOFUSE_ENDPOINT',
    'timeout_ms':              'LINGOFUSE_TIMEOUT',
    'default_app':             'LINGOFUSE_APP',
    'threaded':                'LINGOFUSE_THREADED',
    'forward_only':            'LINGOFUSE_FORWARD_ONLY',
    'debug':                   'LINGOFUSE_DEBUG',
    'no_precheck':             'LINGOFUSE_NO_PRECHECK',
    'normalize_json':          'LINGOFUSE_NORMALIZE_JSON',
    'log_file':                'LINGOFUSE_LOG_FILE',
    'bridge_app_name':         'LINGOFUSE_BRIDGE_APP',
    'bridge_api_name':         'LINGOFUSE_BRIDGE_API',
    'bridge_repair_api_name':  'LINGOFUSE_BRIDGE_REPAIR_API',
}


# ======================================================================
# Logging
# ======================================================================
#
# The logger object is created here, but the level and file sink are
# configured by `_configure_logging()`, which is called exactly once
# from `_run_bridge()`, AFTER the configuration instance has been
# fully populated.
#
# A module-level logger is created up front because the environment
# helpers below may need to warn about a malformed variable before
# the user-facing logging configuration has been applied.
# ======================================================================

logger = logging.getLogger('LingoFuseBridge')
logger.setLevel(logging.INFO)

_formatter = logging.Formatter('[%(levelname)s] %(message)s')

_stderr_handler = logging.StreamHandler(sys.stderr)
_stderr_handler.setFormatter(_formatter)
logger.addHandler(_stderr_handler)


# ======================================================================
# Environment-variable readers
# ----------------------------------------------------------------------
# These three functions are the ONLY place in the entire module that
# reads os.environ. They are called once per field, exactly once,
# from `_apply_environment_defaults()`.
# ======================================================================

def _env_str(name: str) -> Optional[str]:
    """
    Read a raw string from the environment.

    Returns None when the variable is unset, and an empty string when
    the variable is set to the empty string. The distinction matters
    for `log_file` (empty string = explicit "no log file").
    """
    if name in os.environ:
        return os.environ[name]
    return None


def _env_int(name: str) -> Optional[int]:
    """Read an int from the environment. Returns None when unset."""
    raw = _env_str(name)
    if raw is None:
        return None
    try:
        return int(raw)
    except ValueError:
        # Log the malformed value and fall through to the default.
        # This happens during startup, before user logging is
        # configured, so use the module logger directly.
        logger.warning(
            "Environment variable %s=%r is not a valid integer; "
            "the default will be used",
            name, raw,
        )
        return None


def _env_bool(name: str) -> Optional[bool]:
    """
    Read a boolean from the environment.

    Accepts: 1 / 0, true / false, yes / no, on / off (case-insensitive).
    Returns None when the variable is unset or malformed.
    """
    raw = _env_str(name)
    if raw is None:
        return None
    normalized = raw.strip().lower()
    if normalized in ('1', 'true', 'yes', 'on'):
        return True
    if normalized in ('0', 'false', 'no', 'off'):
        return False
    logger.warning(
        "Environment variable %s=%r is not a valid boolean; "
        "the default will be used",
        name, raw,
    )
    return None


# ======================================================================
# Configuration loading (phase 1: environment)
# ======================================================================

def _apply_environment_defaults(cfg: BridgeConfig) -> None:
    """
    Load defaults from the environment into `cfg`.

    Called exactly once, from `main()`, before `_apply_command_line()`.
    No other function in this module reads `os.environ`.
    """
    value = _env_str(_ENV_VAR_TABLE['host'])
    if value is not None:
        cfg.host = value

    value = _env_int(_ENV_VAR_TABLE['port'])
    if value is not None:
        cfg.port = value

    value = _env_str(_ENV_VAR_TABLE['endpoint'])
    if value is not None:
        cfg.endpoint = value

    value = _env_int(_ENV_VAR_TABLE['timeout_ms'])
    if value is not None:
        cfg.timeout_ms = value

    # `default_app` distinguishes "unset" from "explicitly empty":
    # an unset variable leaves the field as None, an explicit empty
    # string sets it to ''.
    raw = _env_str(_ENV_VAR_TABLE['default_app'])
    if raw is not None:
        cfg.default_app = raw if raw else None

    value = _env_bool(_ENV_VAR_TABLE['threaded'])
    if value is not None:
        cfg.threaded = value

    # forward_only: the environment variable overrides the built-in
    # default AND any value the embedding application may have
    # pre-set on `config.forward_only`. The command line (phase 2)
    # can still override this in turn.
    value = _env_bool(_ENV_VAR_TABLE['forward_only'])
    if value is not None:
        cfg.forward_only = value

    value = _env_bool(_ENV_VAR_TABLE['debug'])
    if value is not None:
        cfg.debug = value

    value = _env_bool(_ENV_VAR_TABLE['no_precheck'])
    if value is not None:
        cfg.no_precheck = value

    value = _env_bool(_ENV_VAR_TABLE['normalize_json'])
    if value is not None:
        cfg.normalize_json = value

    raw = _env_str(_ENV_VAR_TABLE['log_file'])
    if raw is not None:
        cfg.log_file = raw if raw else None

    raw = _env_str(_ENV_VAR_TABLE['bridge_app_name'])
    if raw is not None:
        cfg.bridge_app_name = raw if raw else DEFAULT_BRIDGE_APP_NAME

    raw = _env_str(_ENV_VAR_TABLE['bridge_api_name'])
    if raw is not None:
        cfg.bridge_api_name = raw if raw else DEFAULT_BRIDGE_API_NAME

    raw = _env_str(_ENV_VAR_TABLE['bridge_repair_api_name'])
    if raw is not None:
        cfg.bridge_repair_api_name = (
            raw if raw else DEFAULT_BRIDGE_REPAIR_API_NAME
        )


# ======================================================================
# Configuration loading (phase 2: command line)
# ======================================================================

def _apply_command_line(cfg: BridgeConfig, argv) -> None:
    """
    Parse command-line arguments and write them into `cfg`.

    Called exactly once, from `main()`, after
    `_apply_environment_defaults()`. Every argument overrides the
    corresponding environment-derived value.

    The default value for each argparse argument is NOT the constant
    DEFAULT_*, but the current value of the corresponding field in
    `cfg`. This is what makes the command line override the
    environment: argparse keeps the environment-derived value when
    the user does not pass the flag, and substitutes the user's
    value when the flag is present.

    argparse automatically provides a --help / -h option, so
    `python bridge.py --help` prints the full usage text and exits
    with status 0.
    """
    parser = argparse.ArgumentParser(
        prog='bridge',
        description=(
            "LingoFuse HTTP Bridge - bidirectional HTTP <-> LingoFuse "
            "POST gateway with canonical JSON normalization and a "
            "LingoFuse-callable JSON repair API. "
            "Environment variables are read as defaults; command-line "
            "arguments override them."
        ),
        epilog=(
            "Environment variables: "
            "LINGOFUSE_HOST, LINGOFUSE_PORT, LINGOFUSE_ENDPOINT, "
            "LINGOFUSE_TIMEOUT, LINGOFUSE_APP, LINGOFUSE_THREADED, "
            "LINGOFUSE_FORWARD_ONLY, LINGOFUSE_DEBUG, "
            "LINGOFUSE_NO_PRECHECK, LINGOFUSE_NORMALIZE_JSON, "
            "LINGOFUSE_LOG_FILE, LINGOFUSE_BRIDGE_APP, "
            "LINGOFUSE_BRIDGE_API, LINGOFUSE_BRIDGE_REPAIR_API. "
            "Command-line arguments take precedence over environment "
            "variables, which take precedence over built-in defaults. "
            "Set LINGOFUSE_JSON_REPAIR=0 to disable the unified JSON "
            "repair preprocessor (bridge Layer 2 and the repair API)."
        ),
    )

    # --- inbound HTTP server ---
    parser.add_argument(
        '--host',
        default=cfg.host,
        help=f"HTTP listening address (default: {cfg.host})",
    )
    parser.add_argument(
        '--port',
        type=int,
        default=cfg.port,
        help=f"HTTP listening port (default: {cfg.port})",
    )

    # --- operating mode ---
    parser.add_argument(
        '--forward-only',
        dest='forward_only',
        action='store_true',
        default=cfg.forward_only,
        help=(
            "Enable forward-only mode: DISABLE the HTTP listener and "
            "only serve the LingoFuse Call APIs (outbound HTTP POST "
            "proxy and JSON repair). No TCP port is opened. This "
            "overrides the LINGOFUSE_FORWARD_ONLY environment "
            "variable and any programmatic pre-set of "
            "config.forward_only."
        ),
    )
    parser.add_argument(
        '--no-forward-only',
        dest='forward_only',
        action='store_false',
        help=(
            "Disable forward-only mode (default). The HTTP listener "
            "is started normally."
        ),
    )

    # --- LingoFuse connection ---
    parser.add_argument(
        '--endpoint',
        default=cfg.endpoint,
        help=(
            f"LingoFuse service endpoint (default: {cfg.endpoint}). "
            f"This is the address the bridge connects to as a client "
            f"and the address on which the bridge's own App is "
            f"registered."
        ),
    )
    parser.add_argument(
        '--timeout',
        dest='timeout_ms',
        type=int,
        default=cfg.timeout_ms,
        help=(
            f"Default LingoFuse call timeout in milliseconds "
            f"(default: {cfg.timeout_ms})"
        ),
    )
    parser.add_argument(
        '--app',
        dest='default_app',
        default=cfg.default_app,
        help=(
            "Default target application name (used when the inbound "
            "URL path has only an API name). Ignored in forward-only "
            "mode."
        ),
    )

    # --- Boolean flags ---
    # Mutually exclusive pairs. The environment-derived value is used
    # when neither flag is present.
    parser.add_argument(
        '--threaded',
        dest='threaded',
        action='store_true',
        default=cfg.threaded,
        help="Enable multi-threaded HTTP request handling (default)",
    )
    parser.add_argument(
        '--no-threaded',
        dest='threaded',
        action='store_false',
        help="Disable multi-threaded HTTP request handling",
    )

    parser.add_argument(
        '--debug',
        dest='debug',
        action='store_true',
        default=cfg.debug,
        help="Enable debug logging of request/response details",
    )
    parser.add_argument(
        '--no-debug',
        dest='debug',
        action='store_false',
        help="Disable debug logging",
    )

    parser.add_argument(
        '--no-precheck',
        dest='no_precheck',
        action='store_true',
        default=cfg.no_precheck,
        help=(
            "Disable the inbound API pre-check (check_api) to avoid "
            "cache false negatives. Ignored in forward-only mode."
        ),
    )
    parser.add_argument(
        '--precheck',
        dest='no_precheck',
        action='store_false',
        help=(
            "Enable the inbound API pre-check (default). Ignored in "
            "forward-only mode."
        ),
    )

    parser.add_argument(
        '--normalize-json',
        dest='normalize_json',
        action='store_true',
        default=cfg.normalize_json,
        help=(
            "Canonicalize JSON payloads in both directions: repair "
            "BOM / trailing NUL / trailing comma / encoding issues "
            "and re-emit as compact UTF-8 JSON (default). "
            "Malformed payloads that the unified repair engine can "
            "recover are also rewritten; payloads it cannot recover "
            "are forwarded unchanged."
        ),
    )
    parser.add_argument(
        '--no-normalize-json',
        dest='normalize_json',
        action='store_false',
        help=(
            "Disable JSON normalization. The inbound path becomes a "
            "pure byte-level passthrough. The outbound path always "
            "serializes through dumps_json and is unaffected."
        ),
    )

    # --- diagnostics ---
    parser.add_argument(
        '--log-file',
        dest='log_file',
        default=cfg.log_file,
        help="Path to log file (default: stderr)",
    )

    # --- outbound LingoFuse Call API registration ---
    parser.add_argument(
        '--bridge-app',
        dest='bridge_app_name',
        default=cfg.bridge_app_name,
        help=(
            f"LingoFuse application name for the bridge's own App "
            f"(default: {cfg.bridge_app_name}). This name must be "
            f"unique across the mesh."
        ),
    )
    parser.add_argument(
        '--bridge-api',
        dest='bridge_api_name',
        default=cfg.bridge_api_name,
        help=(
            f"LingoFuse API name for the outbound POST proxy "
            f"(default: {cfg.bridge_api_name}). Callers invoke it as "
            f"<bridge_app>.<bridge_api>."
        ),
    )
    parser.add_argument(
        '--bridge-repair-api',
        dest='bridge_repair_api_name',
        default=cfg.bridge_repair_api_name,
        help=(
            f"LingoFuse API name for the JSON repair service "
            f"(default: {cfg.bridge_repair_api_name}). Callers invoke "
            f"it as <bridge_app>.<bridge_repair_api> and pass a JSON "
            f"string; the repaired string is returned."
        ),
    )

    args = parser.parse_args(argv)

    # Write every parsed value back into the single configuration
    # instance. After this function returns, `cfg` is frozen for the
    # rest of the process lifetime.
    cfg.host = args.host
    cfg.port = args.port
    cfg.forward_only = args.forward_only
    cfg.endpoint = args.endpoint
    cfg.timeout_ms = args.timeout_ms
    cfg.default_app = args.default_app if args.default_app else None
    cfg.threaded = args.threaded
    cfg.debug = args.debug
    cfg.no_precheck = args.no_precheck
    cfg.normalize_json = args.normalize_json
    cfg.log_file = args.log_file if args.log_file else None
    cfg.bridge_app_name = args.bridge_app_name
    cfg.bridge_api_name = args.bridge_api_name
    cfg.bridge_repair_api_name = args.bridge_repair_api_name


# ======================================================================
# Logging configuration
# ======================================================================

def _configure_logging(cfg: BridgeConfig) -> None:
    """
    Configure the module logger from the final configuration.

    Called exactly once, from `_run_bridge()`, after `main()` has
    populated `cfg`. Reads ONLY from `cfg`, never from os.environ.
    """
    if cfg.debug:
        logger.setLevel(logging.DEBUG)
        # Reduce noise from Werkzeug's request log.
        logging.getLogger('werkzeug').setLevel(logging.ERROR)
    else:
        logger.setLevel(logging.INFO)

    if cfg.log_file:
        file_handler = logging.FileHandler(cfg.log_file, encoding=ENCODING)
        file_handler.setFormatter(_formatter)
        logger.addHandler(file_handler)


# ======================================================================
# Global state for the bridge's own LingoFuse App
# ======================================================================
#
# We keep a strong reference to the App handle and to the ctypes
# callback objects so that they are not garbage-collected while the
# LingoFuse library still holds their pointers. Both are written once
# during _setup_network(), before the HTTP server starts, and only
# read (or cleared) afterwards.
# ======================================================================

_bridge_app_handle = None
_bridge_app_callbacks = []


# ======================================================================
# JSON normalization (inbound path)
# ----------------------------------------------------------------------
# The bridge's core inbound payload transformation. Given an arbitrary
# byte payload, it attempts to turn the payload into canonical UTF-8
# JSON.
#
# The canonical form is defined by lingofuse.lf_io.dumps_json, which
# is the toolchain-wide serialization policy. The bridge therefore
# uses dumps_json() for its output rather than a local json.dumps
# call. This guarantees that a payload re-emitted by the bridge is
# byte-identical to what any other toolchain component would produce
# for the same parsed object.
#
# Binary safety is a hard requirement. If a payload cannot be parsed
# as JSON after both repair layers (see below), the original bytes are
# returned UNCHANGED.
#
# The repair stack has two layers:
#
#   Layer 1: `_try_repair_json()`. Conservative, in-module repairs
#            that never change the meaning of a well-formed document
#            (strip a stray Unicode BOM character, remove trailing
#            commas before a closing brace or bracket).
#
#   Layer 2: `lingofuse.json_repair_preprocess.repair_json_text`.
#            The toolchain-wide repair engine. More aggressive, but
#            it re-validates its own output against strict JSON, so
#            binary safety is preserved. Called with
#            report_failure=False because a non-JSON payload is a
#            legitimate passthrough outcome for the bridge.
# ======================================================================

# Pre-compiled regex matching a trailing comma before a closing brace
# or bracket, optionally separated by whitespace. Applied by
# `_try_repair_json()`.
_TRAILING_COMMA_RE = re.compile(r',(\s*[}\]])')

_BOM_UTF8 = codecs.BOM_UTF8
_BOM_UTF16_LE = codecs.BOM_UTF16_LE
_BOM_UTF16_BE = codecs.BOM_UTF16_BE

# Status tokens returned by `normalize_json_bytes()`.
STATUS_PASSTHROUGH = 'passthrough'  # not JSON; forwarded as-is
STATUS_CANONICAL = 'canonical'      # already valid UTF-8 JSON
STATUS_REPAIRED = 'repaired'        # repaired, then re-serialized
STATUS_RECODED = 'recoded'          # valid JSON in another encoding

# Content type to use for each status on the inbound response path.
_RESPONSE_CONTENT_TYPES = {
    STATUS_CANONICAL: 'application/json; charset=utf-8',
    STATUS_REPAIRED: 'application/json; charset=utf-8',
    STATUS_RECODED: 'application/json; charset=utf-8',
    STATUS_PASSTHROUGH: 'application/octet-stream',
}


def _try_repair_json(text: str) -> Optional[str]:
    """
    Apply a small set of SAFE repairs to a JSON-like string.

    This is Layer 1 of the bridge's repair stack. The repairs are
    deliberately conservative: each must produce a string that a
    strict JSON parser accepts without changing the semantic meaning
    of the original document. More aggressive repairs are delegated
    to Layer 2 (lingofuse.json_repair_preprocess.repair_json_text),
    which is applied separately inside normalize_json_bytes().

    Currently handled:
        * A stray Unicode BOM character (U+FEFF) at the start.
        * Trailing commas before a closing brace or bracket.

    Returns the repaired string, or None when no repair is applicable.
    """
    s = text.strip()
    if not s:
        return None

    # Strip a stray Unicode BOM character that may have survived the
    # byte-level BOM stripping step (e.g. a double-encoded BOM).
    if s.startswith('\ufeff'):
        s = s[1:].lstrip()
        if not s:
            return None

    # Reject anything that does not start with a JSON value token.
    if s[0] not in '{["-0123456789tfn':
        return None

    # Remove trailing commas before a closing brace or bracket.
    return _TRAILING_COMMA_RE.sub(r'\1', s)


def normalize_json_bytes(raw: bytes) -> Tuple[bytes, str]:
    """
    Normalize a byte payload into canonical UTF-8 JSON.

    Returns (normalized_bytes, status). The status is informational;
    the caller decides what to do with it.

    Steps, in order:

      1. Strip a leading UTF-8 BOM. A UTF-16 BOM immediately returns
         passthrough, because guessing UTF-16 endianness on a payload
         that may be binary is unsafe.

      2. Strip trailing NUL bytes. This handles payloads produced by
         a Pascal LF_WriteString call.

      3. Decode to a Python str, preferring UTF-8, then GBK (CP936),
         then Latin-1 (which never fails).

      4. Strict json.loads(). On success, classify as canonical
         (or recoded, when the source encoding was not UTF-8).

      5. On failure, run the two-layer repair stack:

           5a. Layer 1 - `_try_repair_json()`, the bridge's own
               conservative repairs.

           5b. Layer 2 -
               `lingofuse.json_repair_preprocess.repair_json_text`,
               the toolchain-wide repair engine. Called with
               report_failure=False, because a non-JSON payload is a
               legitimate passthrough outcome for the bridge.

         If either layer produces a string that parses as strict
         JSON, classify as repaired. Otherwise fall through to
         step 7 (passthrough).

      6. Re-serialize with lingofuse.lf_io.dumps_json(), which is the
         toolchain-wide canonical policy. Encode the result to UTF-8
         with errors="replace" so that a lone surrogate (which can
         only arise from a non-conformant producer) is emitted as
         U+FFFD instead of raising UnicodeEncodeError. See the
         module docstring section "UNICODE ENCODING SAFETY".

      7. On total failure, return the ORIGINAL BYTES UNCHANGED with
         status passthrough. Binary safety is preserved.

    Idempotence
    -----------
    Calling this function twice on the same input is safe. If the
    first call produced canonical output, the second call classifies
    it as canonical and re-serializes it to the identical bytes.

    Logging
    -------
    * Status canonical / recoded -> no log message.
    * Status repaired            -> the unified engine emits a
                                    WARNING naming this function as
                                    the source. Layer 1 alone does
                                    not emit a log message.
    * Status passthrough         -> no log message from the repair
                                    stack (report_failure=False
                                    suppresses the ERROR branch of
                                    the unified engine).
    """
    if not raw:
        return raw, STATUS_PASSTHROUGH

    original = raw

    # ------------------------------------------------------------------
    # Step 1: strip UTF-8 BOM (or bail out on UTF-16 BOM).
    # ------------------------------------------------------------------
    if raw.startswith(_BOM_UTF8):
        raw = raw[len(_BOM_UTF8):]
    elif raw.startswith(_BOM_UTF16_LE) or raw.startswith(_BOM_UTF16_BE):
        return original, STATUS_PASSTHROUGH

    # ------------------------------------------------------------------
    # Step 2: strip trailing NUL bytes.
    # ------------------------------------------------------------------
    if raw.endswith(b'\x00'):
        raw = raw.rstrip(b'\x00')
    if not raw:
        return original, STATUS_PASSTHROUGH

    # ------------------------------------------------------------------
    # Step 3: decode to str, preferring UTF-8.
    # ------------------------------------------------------------------
    text: Optional[str] = None
    encoding_used = ENCODING
    for candidate in (ENCODING, 'gbk', 'latin-1'):
        try:
            text = raw.decode(candidate)
            encoding_used = candidate
            break
        except (UnicodeDecodeError, LookupError):
            continue

    if text is None:
        # Unreachable in practice (latin-1 always succeeds), but a
        # defensive guard costs nothing on the cold path.
        return original, STATUS_PASSTHROUGH

    # ------------------------------------------------------------------
    # Step 4: strict JSON parse.
    # ------------------------------------------------------------------
    obj = None
    parsed = False
    try:
        obj = json.loads(text)
        parsed = True
    except json.JSONDecodeError:
        pass

    # ------------------------------------------------------------------
    # Step 5: two-layer repair-and-retry.
    #
    #   5a. Layer 1 - the bridge's own conservative repairs.
    #   5b. Layer 2 - the unified repair preprocessor.
    #
    # Layer 2 re-validates its own output against strict JSON, so any
    # payload that still fails to parse after both layers is treated
    # as non-JSON and forwarded unchanged in step 7.
    # ------------------------------------------------------------------
    repaired_flag = False
    if not parsed:
        candidate_text = _try_repair_json(text)
        if candidate_text is not None:
            try:
                obj = json.loads(candidate_text)
                parsed = True
                repaired_flag = True
            except json.JSONDecodeError:
                pass

    if not parsed:
        # Layer 2. report_failure=False: an unrepairable payload is
        # NOT an error for the bridge; it simply falls through to the
        # passthrough branch below. The unified engine still emits
        # its own WARNING when a repair succeeds, which is the signal
        # we want to surface to the operator.
        unified_text = repair_json_text(
            text,
            source="bridge.normalize_json_bytes",
            report_failure=False,
        )
        if unified_text != text:
            try:
                obj = json.loads(unified_text)
                parsed = True
                repaired_flag = True
            except json.JSONDecodeError:
                # The unified engine validated its own output, so
                # this branch should be unreachable. Guard anyway: if
                # it ever triggers, we fall through to the passthrough
                # branch below, preserving binary safety.
                pass

    if not parsed:
        # Not JSON after both repair layers. Forward unchanged to
        # preserve binary safety.
        return original, STATUS_PASSTHROUGH

    # ------------------------------------------------------------------
    # Step 6: canonical re-serialization using the toolchain policy.
    #
    # dumps_json() is imported from lingofuse.lf_io, so the output is
    # guaranteed to match what every other toolchain component would
    # produce for the same parsed object:
    #
    #     json.dumps(obj, ensure_ascii=False, default=str)
    #
    # The default str() fallback never triggers here because `obj` is
    # a tree that was just produced by json.loads(), but calling the
    # canonical function keeps the policy in one place.
    #
    # The encode() call uses errors="replace" so that a lone surrogate
    # in the parsed object (which can only come from a non-conformant
    # producer) is emitted as U+FFFD instead of raising. See the
    # module docstring section "UNICODE ENCODING SAFETY".
    # ------------------------------------------------------------------
    canonical_str = dumps_json(obj)
    canonical_bytes = canonical_str.encode(ENCODING, errors="replace")

    # ------------------------------------------------------------------
    # Step 7: classify and return.
    # ------------------------------------------------------------------
    if repaired_flag:
        return canonical_bytes, STATUS_REPAIRED
    if encoding_used != ENCODING:
        return canonical_bytes, STATUS_RECODED
    return canonical_bytes, STATUS_CANONICAL


# ======================================================================
# Flask application
# ======================================================================
#
# The Flask app object is constructed at module import time, but it is
# only ever RUN by _run_bridge() when forward_only is False. In
# forward-only mode the app object still exists (so the module-level
# symbols are stable), but no listener is started and no route is ever
# reached.
# ======================================================================

app = Flask(__name__)
# Disable Flask's default request logger; we handle logging ourselves.
app.logger.disabled = True
logging.getLogger('werkzeug').setLevel(logging.ERROR)


@app.after_request
def _after_request(response: Response) -> Response:
    """
    Add permissive CORS headers to every response.

    Wrapped in a try/except so that an unexpected response object can
    never prevent the bridge from returning a response. CORS is a
    courtesy, not a correctness requirement.
    """
    try:
        response.headers['Access-Control-Allow-Origin'] = '*'
        response.headers['Access-Control-Allow-Headers'] = 'Content-Type'
        response.headers['Access-Control-Allow-Methods'] = 'POST, GET, OPTIONS'
    except Exception:
        logger.exception("Failed to attach CORS headers to response")
    return response


# ======================================================================
# Cleanup
# ======================================================================

# Idempotence guard. `cleanup()` is registered on atexit AND called
# from the finally block of `_run_bridge()`. Without this flag it
# would run twice on every normal shutdown.
_cleanup_done = False


def cleanup() -> None:
    """
    Stop the LingoFuse main thread and shut down the library.

    Cleanup order matters:

        1. Clear network event callbacks first, so that no user
           callback can fire during the shutdown transition, and
           release the Python-side strong references held by
           `lingofuse.network_events`.

        2. Stop the LingoFuse main thread (LF_ExitMainThread), so that
           no further LingoFuse callback can fire.

        3. Free the bridge's own App (LF_FreeApp) and release the
           ctypes callback objects.

        4. Unload the library (LF_Shutdown).

    Safe to call multiple times.
    """
    global _cleanup_done, _bridge_app_handle, _bridge_app_callbacks
    if _cleanup_done:
        return
    _cleanup_done = True

    try:
        from lingofuse.network_events import clear_network_event
        clear_network_event()
    except Exception:
        logger.exception("clear_network_event failed during cleanup")

    try:
        LF_ExitMainThread()
    except Exception:
        logger.exception("LF_ExitMainThread failed during cleanup")

    # Free the App BEFORE clearing the callback list. LF_FreeApp
    # detaches the App from all clients, and only after it returns
    # is it safe for the Python-side callback objects to be
    # garbage-collected.
    if _bridge_app_handle is not None:
        try:
            LF_FreeApp(_bridge_app_handle)
        except Exception:
            logger.exception("LF_FreeApp failed during cleanup")
        finally:
            _bridge_app_handle = None

    _bridge_app_callbacks.clear()

    try:
        LF_Shutdown()
    except Exception:
        logger.exception("LF_Shutdown failed during cleanup")

    logger.info("LingoFuse resources released")


atexit.register(cleanup)


# ======================================================================
# Helpers
# ======================================================================

def _json_error_response(code: int, msg: str,
                         http_status: int = 200) -> Response:
    """
    Build a JSON error response.

    Error codes (negative, bridge-level):

        -1  Remote call failed: timeout, null handle from LF_Call,
            LingoFuseError, or any unexpected internal exception.
        -2  Request shape error: the URL path could not be parsed into
            (app_name, api_name), or no default app was configured
            and the path omitted the app segment. Returned with HTTP
            400.
        -3  API pre-check failed: check_api returned False after the
            configured number of retries.

    The JSON body is produced via lingofuse.lf_io.dumps_json, so it is
    guaranteed to be canonical UTF-8 with no \\uXXXX escapes.

    The final .encode(ENCODING) uses errors="replace" (G2 fix) so that
    a `msg` that somehow contains a lone surrogate (which can only
    come from a non-conformant producer) is emitted as U+FFFD instead
    of raising UnicodeEncodeError and aborting the response. See the
    module docstring section "UNICODE ENCODING SAFETY".
    """
    body = dumps_json({"code": code, "error": msg}).encode(
        ENCODING, errors="replace",
    )
    return app.response_class(
        response=body,
        status=http_status,
        mimetype='application/json; charset=utf-8',
    )


def _drain_status(n: int = 3) -> None:
    """
    Drain up to `n` pending status messages from the LingoFuse internal
    queue and forward them to the bridge logger.

    Diagnostic only. Any failure is swallowed so that a logging aid can
    never turn into a request-handling failure.
    """
    try:
        pending = get_status_num()
    except Exception as e:
        logger.debug("get_status_num() failed: %s", e)
        return

    if pending <= 0:
        return

    for _ in range(min(n, pending)):
        try:
            msg = get_status()
        except Exception as e:
            logger.debug("get_status() failed: %s", e)
            return
        if msg:
            logger.info("LingoFuse status: %s", msg)


def _decode_text_with_fallback(raw: bytes) -> Tuple[Optional[str], str]:
    """
    Decode a byte payload into text using the bridge's encoding fallback
    chain: UTF-8 -> GBK -> Latin-1.

    Returns (text, encoding_used). `text` is None only if every
    candidate raised, which is unreachable in practice because Latin-1
    accepts every byte sequence. The second element is meaningful only
    when `text` is not None.
    """
    for candidate in (ENCODING, 'gbk', 'latin-1'):
        try:
            return raw.decode(candidate), candidate
        except (UnicodeDecodeError, LookupError):
            continue
    return None, ENCODING


# ======================================================================
# Outbound LingoFuse Call API: HTTP POST proxy
# ======================================================================

def _normalize_headers_dict(headers) -> dict:
    """
    Return a plain dict with lower-cased header names.

    HTTP header names are case-insensitive. Both `requests` and Flask
    use case-insensitive containers internally, but the containers are
    not JSON-serializable. We therefore copy them into a plain dict
    with lower-cased keys, which is stable across Python versions and
    easy for a JSON consumer to use.
    """
    if headers is None:
        return {}
    try:
        items = headers.items()
    except AttributeError:
        # Not a mapping; give up and return the object as-is wrapped
        # in a dict keyed by "_raw". This should never happen in
        # practice because both requests and Flask return mappings.
        return {"_raw": str(headers)}
    return {str(k).lower(): str(v) for k, v in items}


def _parse_outbound_request(req) -> Tuple[Optional[dict], Optional[str]]:
    """
    Validate the JSON request object sent by a LingoFuse caller.

    Returns (parsed, error_message). Exactly one of the two is None.

    The request must be a JSON object with at least a "url" field.
    All other fields are optional and receive documented defaults.
    """
    if req is None:
        return None, "Empty or invalid JSON request"

    if not isinstance(req, dict):
        return None, "Request must be a JSON object"

    url = req.get("url")
    if not url or not isinstance(url, str):
        return None, "Missing or invalid 'url' field"

    method = req.get("method", "POST")
    if not isinstance(method, str) or method.upper() not in ALLOWED_HTTP_METHODS:
        return None, (
            f"Unsupported HTTP method: {method!r}. "
            f"Allowed: {sorted(ALLOWED_HTTP_METHODS)}"
        )

    headers = req.get("headers", {})
    if headers is None:
        headers = {}
    if not isinstance(headers, dict):
        return None, "'headers' must be a JSON object"

    timeout = req.get("timeout", None)
    if timeout is not None:
        if not isinstance(timeout, (int, float)) or timeout <= 0:
            return None, "'timeout' must be a positive number of seconds"
        if timeout > MAX_OUTBOUND_TIMEOUT_S:
            timeout = MAX_OUTBOUND_TIMEOUT_S

    return {
        "url": url,
        "method": method.upper(),
        "headers": headers,
        "body": req.get("body", None),
        "timeout": timeout,
    }, None


def _bridge_post_callback(trigger, inp, out):
    """
    LingoFuse Call API callback: sends an HTTP request to a given URL
    and returns the response as JSON.

    This function runs on a LingoFuse worker thread. It MUST NOT call
    any blocking LingoFuse function (LF_Call, LF_LocalCall, ...); see
    the LingoFuse documentation for the callback contract.

    Input DataHandle: JSON request object (see module docstring).
    Output DataHandle: JSON response object (see module docstring).

    Exception isolation
    -------------------
    All exceptions are caught and converted into a JSON error response
    written to the output handle. No exception is allowed to propagate
    back into the C stack. This matches the behavior of the LingoFuse
    Pascal core (TLF_Engine.Execute_Call).

    JSON policy
    -----------
    Both the inbound request and the outbound response are read and
    written through DataHandle.read_json() / write_json(), which are
    thin wrappers around lingofuse.lf_io. The request body sent to the
    remote HTTP server is serialized with dumps_json(), so no \\uXXXX
    escape ever appears on the HTTP wire.

    The dumps_json(...).encode(ENCODING) call for the outbound body
    uses errors="replace" (G2 fix) so that a request body containing
    a lone surrogate is emitted as U+FFFD instead of raising
    UnicodeEncodeError. See the module docstring section
    "UNICODE ENCODING SAFETY".
    """
    # Wrap the raw ctypes handles so we can use the high-level JSON
    # I/O methods. owned=False: the library owns these handles and
    # will free them after the callback returns.
    h_in = DataHandle._from_raw(inp, owned=False)
    h_out = DataHandle._from_raw(out, owned=False)

    try:
        # ------------------------------------------------------------------
        # 1. Read and validate the request object.
        # ------------------------------------------------------------------
        req = h_in.read_json()
        parsed, err = _parse_outbound_request(req)
        if err is not None:
            logger.warning("Outbound request rejected: %s", err)
            h_out.write_json({"error": err})
            return

        url = parsed["url"]
        method = parsed["method"]
        headers = parsed["headers"]
        body_obj = parsed["body"]
        timeout = parsed["timeout"]
        if timeout is None:
            timeout = config.timeout_ms / 1000.0

        # ------------------------------------------------------------------
        # 2. Build the outbound request body.
        #
        # We serialize the body ourselves with dumps_json(), NOT with
        # requests' json= shortcut. The json= shortcut uses
        # json.dumps(ensure_ascii=True), which would escape every
        # non-ASCII character as \\uXXXX and violate the toolchain's
        # canonical JSON policy. Sending explicit UTF-8 bytes keeps
        # the wire format identical to what every other toolchain
        # component would produce for the same object.
        #
        # errors="replace" (G2 fix): a lone surrogate from a
        # non-conformant caller is downgraded to U+FFFD instead of
        # raising.
        # ------------------------------------------------------------------
        if body_obj is None:
            body_bytes = None
        else:
            body_bytes = dumps_json(body_obj).encode(
                ENCODING, errors="replace",
            )
            # Only inject a Content-Type if the caller did not
            # provide one. Comparison is case-insensitive because we
            # normalize the caller-supplied keys for the check only.
            lower_keys = {str(k).lower() for k in headers.keys()}
            if 'content-type' not in lower_keys:
                headers = dict(headers)
                headers['Content-Type'] = 'application/json; charset=utf-8'

        if config.debug:
            logger.debug(
                "Outbound HTTP: method=%s url=%s timeout=%.3fs "
                "body_bytes=%s",
                method, url, timeout,
                len(body_bytes) if body_bytes is not None else 0,
            )

        # ------------------------------------------------------------------
        # 3. Perform the HTTP request.
        #
        # requests.request() is thread-safe: it creates a fresh
        # connection per call, so concurrent invocations from
        # different LingoFuse worker threads do not interfere.
        # ------------------------------------------------------------------
        resp = requests.request(
            method=method,
            url=url,
            headers=headers,
            data=body_bytes,
            timeout=timeout,
        )

        # ------------------------------------------------------------------
        # 4. Build the response object.
        #
        # The HTTP response body is inspected:
        #   - If it parses as JSON, it is embedded as a JSON value.
        #   - Otherwise, it is embedded as a raw string.
        # This never corrupts the payload; the caller sees exactly
        # what the remote server sent.
        # ------------------------------------------------------------------
        try:
            resp_body = resp.json()
        except ValueError:
            # Not JSON. Fall back to a text representation. Some
            # binary responses cannot be decoded as UTF-8; in that
            # case we use a lossy decode so we never raise here.
            resp_body = resp.content.decode(ENCODING, errors='replace')

        result = {
            "status_code": resp.status_code,
            "headers": _normalize_headers_dict(resp.headers),
            "body": resp_body,
        }

        # write_json() uses lingofuse.lf_io.write_json internally,
        # which serializes via dumps_json() and appends the NUL
        # terminator. The LingoFuse caller reads it back through
        # DataHandle.read_json(), so the round-trip is canonical.
        h_out.write_json(result)

    except requests.Timeout:
        logger.warning("Outbound request timed out")
        try:
            h_out.write_json({"error": "HTTP request timed out"})
        except Exception:
            logger.exception("Failed to write timeout error response")
    except requests.RequestException as e:
        logger.warning("Outbound request failed: %s", e)
        try:
            h_out.write_json({"error": f"HTTP request failed: {e}"})
        except Exception:
            logger.exception("Failed to write request error response")
    except Exception as e:
        # Catch-all. We must never let an exception escape into the
        # C stack. Log it and try to write a JSON error response.
        logger.exception("Unexpected error in outbound POST callback")
        try:
            h_out.write_json({"error": f"Internal error: {e}"})
        except Exception:
            # Last-resort: if even writing the error fails, there is
            # nothing more we can do.
            pass


# ======================================================================
# LingoFuse Call API: JSON repair service
# ======================================================================
#
# This API gives any LingoFuse caller access to the same unified
# repair engine used by the toolchain's read paths, without requiring
# the caller to have a Python binding or the vendored json_repair
# subpackage.
#
# Contract:
#
#     Input  (DataHandle): arbitrary bytes; usually a UTF-8 encoded
#                          JSON text, possibly malformed, possibly
#                          NUL-terminated.
#
#     Output (DataHandle): UTF-8 encoded text, NUL-terminated. The
#                          returned text is the repaired JSON, or the
#                          original input text when repair was not
#                          possible, or the original raw bytes when
#                          the input could not be decoded as text at
#                          all.
#
# The callback deliberately mirrors the binary-safety policy of
# normalize_json_bytes(): the bridge never silently corrupts a
# payload. Undecodable bytes and unrepairable text are returned
# unchanged.
#
# No-escape guarantee
# -------------------
# repair_json_text() invokes the engine with ensure_ascii=False, so
# the returned text contains no \\uXXXX escape for any character that
# can be emitted literally in UTF-8. This is a hard contract of the
# toolchain (see lingofuse.lf_io.dumps_json) and is preserved on this
# path as well.
# ======================================================================

def _bridge_repair_callback(trigger, inp, out):
    """
    LingoFuse Call API callback: repairs a malformed JSON string.

    Input DataHandle
        A UTF-8 (or, as a fallback, GBK or Latin-1) encoded JSON text.
        The payload may be malformed, may be missing its NUL
        terminator, and may contain a UTF-8 BOM or trailing NULs.

    Output DataHandle
        A UTF-8 encoded, NUL-terminated text. Its content is:

            * The repaired JSON, when the input was malformed but
              repairable.
            * The original text, when the input was already valid
              JSON (returned byte-for-byte identical).
            * The original text, when the input was malformed and
              could not be repaired.
            * The original raw bytes, when the input could not be
              decoded as text by the fallback chain.

    Exception isolation
    -------------------
    All exceptions are caught. No exception is allowed to escape into
    the C stack. On an internal failure, an empty output payload is
    written and the failure is logged.

    Encoding safety (G2 fix)
    ------------------------
    The final encode() uses errors="replace" so that a repaired text
    that somehow contains a lone surrogate (which can only come from
    a non-conformant producer) is emitted as U+FFFD instead of
    raising UnicodeEncodeError. See the module docstring section
    "UNICODE ENCODING SAFETY".

    Threading
    ---------
    Runs on a LingoFuse worker thread. It MUST NOT call any blocking
    LingoFuse function; the callback body only performs pure-Python
    work (byte decoding, repair, re-encoding).
    """
    h_out = DataHandle._from_raw(out, owned=False)

    try:
        # ------------------------------------------------------------------
        # 1. Read the raw payload. read_string_bytes() stops at the
        #    first NUL and returns the bytes before it, or the whole
        #    remaining buffer when no NUL is present.
        # ------------------------------------------------------------------
        raw = read_string_bytes(inp)

        # An empty input is a valid (if degenerate) request. The
        # repaired form of "nothing" is "nothing"; write an empty,
        # NUL-terminated payload and return.
        if not raw:
            write_string_bytes(out, b"")
            return

        # ------------------------------------------------------------------
        # 2. Strip a leading UTF-8 BOM, if present. A UTF-16 BOM is
        #    not something this API tries to repair: the bytes are
        #    forwarded unchanged, mirroring the passthrough policy of
        #    normalize_json_bytes().
        # ------------------------------------------------------------------
        if raw.startswith(_BOM_UTF8):
            raw = raw[len(_BOM_UTF8):]
        elif raw.startswith(_BOM_UTF16_LE) or raw.startswith(_BOM_UTF16_BE):
            write_string_bytes(out, raw)
            return

        # ------------------------------------------------------------------
        # 3. Strip trailing NUL bytes. This is normally redundant
        #    because read_string_bytes() already stopped at the first
        #    NUL, but a producer that sent multiple trailing NULs (or
        #    a producer that did not append a NUL at all but padded
        #    the buffer) is still handled correctly.
        # ------------------------------------------------------------------
        if raw.endswith(b'\x00'):
            raw = raw.rstrip(b'\x00')
        if not raw:
            write_string_bytes(out, b"")
            return

        # ------------------------------------------------------------------
        # 4. Decode to text with the bridge's encoding fallback chain.
        #    If every candidate fails (unreachable in practice, since
        #    Latin-1 accepts every byte sequence), forward the raw
        #    bytes unchanged to preserve binary safety.
        # ------------------------------------------------------------------
        text, _encoding_used = _decode_text_with_fallback(raw)
        if text is None:
            write_string_bytes(out, raw)
            return

        # ------------------------------------------------------------------
        # 5. Run the unified repair engine.
        #
        #    report_failure=True is intentional here: this API exists
        #    specifically so that a caller can delegate repair to the
        #    bridge. An unrepairable payload is a legitimate, expected
        #    outcome that the operator should be able to see in the
        #    log stream. The engine returns the original text in that
        #    case, and the bridge forwards it unchanged.
        #
        #    The engine is guaranteed to have been invoked with
        #    ensure_ascii=False internally (see
        #    lingofuse.json_repair_preprocess), so the returned text
        #    never contains a \\uXXXX escape for a character that can
        #    be emitted literally in UTF-8.
        # ------------------------------------------------------------------
        repaired = repair_json_text(
            text,
            source="bridge._bridge_repair_callback",
            report_failure=True,
        )

        if config.debug:
            logger.debug(
                "Repair API: in_bytes=%d out_chars=%d",
                len(raw), len(repaired),
            )

        # ------------------------------------------------------------------
        # 6. Write the repaired text as a NUL-terminated UTF-8
        #    payload. write_string_bytes() appends the NUL
        #    terminator that the LingoFuse wire protocol requires.
        #
        #    If the repaired text is empty (which can happen when the
        #    input was a whitespace-only payload that the engine
        #    reduced to nothing), an empty NUL-terminated payload is
        #    written, matching the empty-input handling above.
        #
        #    errors="replace" (G2 fix): a repaired text containing a
        #    lone surrogate is downgraded to U+FFFD instead of
        #    raising UnicodeEncodeError.
        # ------------------------------------------------------------------
        write_string_bytes(
            out,
            repaired.encode(ENCODING, errors="replace"),
        )

    except Exception:
        # Catch-all. We must never let an exception escape into the
        # C stack. Log it and write an empty output so the caller
        # receives a well-formed (if empty) response.
        logger.exception("Unexpected error in JSON repair callback")
        try:
            write_string_bytes(out, b"")
        except Exception:
            # Last-resort: if even writing the empty payload fails,
            # there is nothing more we can do.
            pass


# ======================================================================
# Inbound HTTP request handler
# ======================================================================
#
# The route is only ever reached when forward_only is False. In
# forward-only mode the Flask app is never run, so this handler is
# dead code at runtime (but kept in the module so that the symbol
# surface is stable and the file can be unit-tested).
# ======================================================================

@app.route('/', defaults={'path': ''}, methods=['POST', 'OPTIONS'])
@app.route('/<path:path>', methods=['POST', 'OPTIONS'])
def handle_call(path: str):
    """
    Handle an inbound HTTP request and forward it to a LingoFuse App.

    The URL path determines the routing:
        /<app>/<api>  -> call <api> on <app>
        /<api>        -> call <api> on config.default_app
    """
    # CORS preflight.
    if request.method == 'OPTIONS':
        return '', 200

    # ------------------------------------------------------------------
    # Path parsing. str.split('/') always returns at least one element,
    # so an empty path yields [''] which is caught by the empty api_name
    # check below.
    # ------------------------------------------------------------------
    parts = path.strip('/').split('/')
    if len(parts) == 1:
        api_name = parts[0]
        app_name = config.default_app
        if not app_name:
            return _json_error_response(
                -2, "No default app set (use --app)", 400
            )
    else:
        app_name = parts[0]
        api_name = '/'.join(parts[1:])

    if not api_name:
        return _json_error_response(
            -2, "Missing API name in path", 400
        )

    # ------------------------------------------------------------------
    # Optional pre-check. check_api is backed by a broadcast-updated
    # cache, which can lag behind registration by a few seconds, so we
    # retry a small number of times before giving up.
    # ------------------------------------------------------------------
    if not config.no_precheck:
        available = False
        for attempt in range(3):
            if check_api(app_name, api_name):
                available = True
                break
            if config.debug:
                logger.debug(
                    "check_api(%s, %s) attempt %d returned False",
                    app_name, api_name, attempt + 1,
                )
            time.sleep(0.2)

        if not available:
            if config.debug:
                logger.debug(
                    "check_api(%s, %s) failed after 3 attempts",
                    app_name, api_name,
                )
                _drain_status(3)
            return _json_error_response(
                -3,
                f"API '{api_name}' not available for app '{app_name}'",
                200,
            )

    # ------------------------------------------------------------------
    # Read the raw request body, then optionally normalize it.
    #
    # normalize_json_bytes applies the two-layer repair stack
    # (Layer 1: conservative in-module repairs; Layer 2: the unified
    # lingofuse.json_repair_preprocess engine). A payload that cannot
    # be recognized as JSON even after both layers is returned
    # UNCHANGED with STATUS_PASSTHROUGH, preserving binary safety.
    # ------------------------------------------------------------------
    body = request.get_data()

    request_status = STATUS_PASSTHROUGH
    if config.normalize_json:
        body, request_status = normalize_json_bytes(body)

    if config.debug:
        logger.debug(
            "Inbound request: app=%s api=%s bytes=%d normalize=%s status=%s",
            app_name, api_name, len(body),
            config.normalize_json, request_status,
        )
        if len(body) < 1024:
            logger.debug(
                "Inbound request body: %s",
                body.decode(ENCODING, errors='replace'),
            )
        else:
            logger.debug(
                "Inbound request body (hex, first 64B): %s",
                body.hex()[:64],
            )

    # ------------------------------------------------------------------
    # Forward to the backend and return the response.
    #
    # Both handles are released in finally blocks so that an exception
    # during payload I/O cannot leak a DataHandle.
    # ------------------------------------------------------------------
    try:
        hnd_in = LF_CreateData(cstr(api_name))
        if not hnd_in:
            raise LingoFuseError("Failed to create DataHandle")

        try:
            write_string_bytes(hnd_in, body)
            res_ptr = LF_Call(cstr(app_name), hnd_in, config.timeout_ms)
        finally:
            LF_FreeData(hnd_in)

        if not res_ptr:
            raise LingoFuseError("Remote call returned a null handle")

        try:
            result_bytes = read_string_bytes(res_ptr)
        finally:
            LF_FreeData(res_ptr)

        # ------------------------------------------------------------------
        # Optionally normalize the response.
        #
        # Same two-layer repair stack as the request path: Layer 1 is
        # the bridge's conservative repairs, Layer 2 is the unified
        # engine. Binary-safe: unrepairable payloads pass through
        # unchanged.
        # ------------------------------------------------------------------
        response_status = STATUS_PASSTHROUGH
        if config.normalize_json:
            result_bytes, response_status = normalize_json_bytes(result_bytes)

        if config.debug:
            logger.debug(
                "Inbound response: bytes=%d status=%s",
                len(result_bytes), response_status,
            )
            if len(result_bytes) < 1024:
                logger.debug(
                    "Inbound response body: %s",
                    result_bytes.decode(ENCODING, errors='replace'),
                )
            else:
                logger.debug(
                    "Inbound response body (hex, first 64B): %s",
                    result_bytes.hex()[:64],
                )

        if not result_bytes and config.debug:
            _drain_status(3)

        # Content type is selected from the normalization status:
        # recognized JSON -> application/json, everything else ->
        # application/octet-stream.
        content_type = _RESPONSE_CONTENT_TYPES.get(
            response_status, 'application/octet-stream'
        )

        return Response(
            result_bytes,
            status=200,
            content_type=content_type,
        )

    except TimeoutError:
        return _json_error_response(-1, "Call timeout", 200)
    except LingoFuseError as e:
        return _json_error_response(-1, str(e), 200)
    except Exception as e:
        logger.exception("Unexpected error in inbound call handler")
        return _json_error_response(-1, f"Internal error: {e}", 200)


# ======================================================================
# Network setup
# ======================================================================

def _setup_network(cfg: BridgeConfig) -> bool:
    """
    Establish the bridge's connection to the LingoFuse mesh and
    register the bridge's own Call APIs.

    Two Call APIs are registered on the bridge's App:

        * cfg.bridge_api_name         - outbound HTTP POST proxy
                                        (_bridge_post_callback)
        * cfg.bridge_repair_api_name  - JSON repair service
                                        (_bridge_repair_callback)

    On success, the following globals are populated:
        _bridge_app_handle     : the bridge's own App handle
        _bridge_app_callbacks  : strong references to ctypes callbacks

    On failure, any partially-created resources are released before
    the function returns, so the caller can safely exit without an
    additional cleanup pass.

    Configuration
    -------------
    This function reads ONLY from `cfg`. It does not touch
    os.environ, sys.argv, or any module-level mutable state other
    than the two globals declared above.
    """
    global _bridge_app_handle, _bridge_app_callbacks

    # Local handles for the rollback path. We only assign to the
    # globals once every step has succeeded, so a failure anywhere
    # leaves the globals untouched.
    app_handle = None
    c_post_callback = None
    c_repair_callback = None

    try:
        # ------------------------------------------------------------------
        # 1. Deployment mode.
        #
        # Do not block if the backend is not yet ready. Inbound
        # requests will time out gracefully until the mesh comes
        # online. This makes the bridge suitable for elastic clusters
        # where startup order is unpredictable.
        # ------------------------------------------------------------------
        set_option("Wait_Connection_ReadyOk", "False")

        # ------------------------------------------------------------------
        # 2. Reset any leftover preparation state.
        # ------------------------------------------------------------------
        LF_ResetPrepare()

        # ------------------------------------------------------------------
        # 3. Create the bridge's own App.
        #
        # The App name uses a double-underscore prefix/suffix so that
        # it cannot collide with a business App name (see module
        # docstring). If a previous run left an App with the same name
        # in the mesh, LF_CreateApp still succeeds: the new App
        # replaces the old one after the broadcast propagates.
        # ------------------------------------------------------------------
        app_handle = LF_CreateApp(
            cstr(cfg.bridge_app_name),
            cstr("LingoFuse HTTP Bridge - outbound POST proxy and "
                 "JSON repair service"),
        )
        if not app_handle:
            raise ConnectionError(
                f"Failed to create bridge App '{cfg.bridge_app_name}'"
            )

        # ------------------------------------------------------------------
        # 4a. Register the outbound POST API.
        #
        # The ctypes callback object MUST be kept alive for as long
        # as the library holds its function pointer. We store it in
        # _bridge_app_callbacks.
        # ------------------------------------------------------------------
        c_post_callback = LFCallFunc(_bridge_post_callback)

        ret = LF_RegisterCall(
            app_handle,
            cstr(cfg.bridge_api_name),
            cstr("Proxy an outbound HTTP request and return the response"),
            None,
            c_post_callback,
        )
        if ret != 1:
            raise ConnectionError(
                f"Failed to register bridge API '{cfg.bridge_api_name}' "
                f"on App '{cfg.bridge_app_name}'"
            )

        # ------------------------------------------------------------------
        # 4b. Register the JSON repair API.
        #
        # Same lifetime rule as above: the ctypes callback object must
        # be kept alive for as long as the library holds its pointer.
        #
        # The API name is independent of the POST API name, so a
        # caller that only needs repair does not have to enable or
        # know about the outbound POST proxy, and vice versa.
        # ------------------------------------------------------------------
        c_repair_callback = LFCallFunc(_bridge_repair_callback)

        ret = LF_RegisterCall(
            app_handle,
            cstr(cfg.bridge_repair_api_name),
            cstr("Repair a malformed JSON string and return the repaired "
                 "text; input and output are UTF-8, NUL-terminated"),
            None,
            c_repair_callback,
        )
        if ret != 1:
            raise ConnectionError(
                f"Failed to register bridge repair API "
                f"'{cfg.bridge_repair_api_name}' on App "
                f"'{cfg.bridge_app_name}'"
            )

        # ------------------------------------------------------------------
        # 5. Prepare the client with the bridge's App handle.
        #
        # Passing the App handle to LF_PrepareClient binds the App to
        # the client immediately, so the App becomes discoverable on
        # the mesh as soon as LF_PrepareDone returns.
        #
        # We enable Overlap_Connection before preparing the client,
        # so the bridge does not conflict with an existing client on
        # the same endpoint (e.g. a legacy bridge instance that was
        # started without an App). See LF-NET-001 in the Pascal guide.
        # ------------------------------------------------------------------
        set_option("Overlap_Connection", "True")

        ret = LF_PrepareClient(cstr(cfg.endpoint), app_handle)
        if ret == -1:
            raise ConnectionError(
                f"LF_PrepareClient returned -1 for endpoint "
                f"'{cfg.endpoint}'. Address may already be in use by "
                f"a client that does not allow overlap."
            )

        # ------------------------------------------------------------------
        # 6. Start the LingoFuse main thread.
        # ------------------------------------------------------------------
        ret = LF_PrepareDone()
        if ret != 1:
            raise ConnectionError(f"LF_PrepareDone returned {ret}")

        # ------------------------------------------------------------------
        # 7. All steps succeeded. Publish the globals.
        # ------------------------------------------------------------------
        _bridge_app_handle = app_handle
        _bridge_app_callbacks.append(c_post_callback)
        _bridge_app_callbacks.append(c_repair_callback)

        logger.info(
            "Connected to LingoFuse service: %s and registered APIs "
            "%s.%s (outbound POST) and %s.%s (JSON repair)",
            cfg.endpoint,
            cfg.bridge_app_name, cfg.bridge_api_name,
            cfg.bridge_app_name, cfg.bridge_repair_api_name,
        )
        return True

    except Exception as e:
        logger.error("LingoFuse connection failed: %s", e)

        # ------------------------------------------------------------------
        # Rollback. Release any partially-created resource before
        # returning. The order matches the cleanup order in
        # cleanup(): stop the loop first, then free the App.
        # ------------------------------------------------------------------
        try:
            LF_ExitMainThread()
        except Exception:
            logger.exception("Rollback: LF_ExitMainThread failed")

        if app_handle is not None:
            try:
                LF_FreeApp(app_handle)
            except Exception:
                logger.exception("Rollback: LF_FreeApp failed")

        return False


# ======================================================================
# Startup banner and main loop
# ======================================================================

def _log_startup_banner(cfg: BridgeConfig) -> None:
    """
    Print the effective configuration once, at startup.

    The banner explicitly reports the operating mode (forward-only or
    full) so that operators can tell from a single log line whether
    an HTTP listener is expected.
    """
    logger.info("=== LingoFuse HTTP Bridge (bidirectional POST gateway "
                "with JSON repair service) ===")
    logger.info(
        "Operating mode: %s",
        'FORWARD-ONLY (HTTP listener disabled)'
        if cfg.forward_only else 'FULL (HTTP listener enabled)',
    )
    if cfg.forward_only:
        logger.info(
            "Inbound HTTP listen: DISABLED (forward-only mode)"
        )
    else:
        logger.info(
            "Inbound HTTP listen: http://%s:%d", cfg.host, cfg.port
        )
    logger.info("LingoFuse endpoint: %s", cfg.endpoint)
    logger.info(
        "Inbound default app: %s",
        cfg.default_app or '(must be specified in URL path)',
    )
    logger.info("Inbound call timeout: %dms", cfg.timeout_ms)
    logger.info("HTTP threaded: %s", cfg.threaded)
    logger.info("Debug: %s", cfg.debug)
    logger.info(
        "Inbound API pre-check: %s",
        'Disabled' if cfg.no_precheck else 'Enabled (with retry)',
    )
    logger.info(
        "Inbound JSON normalization: %s",
        'Enabled (request + response, two-layer repair)'
        if cfg.normalize_json else 'Disabled (pure passthrough)',
    )
    logger.info(
        "Outbound POST LingoFuse API: %s.%s",
        cfg.bridge_app_name, cfg.bridge_api_name,
    )
    logger.info(
        "JSON repair LingoFuse API: %s.%s",
        cfg.bridge_app_name, cfg.bridge_repair_api_name,
    )
    if not cfg.forward_only:
        logger.info(
            "Inbound path format: /<app>/<api>  or  /<api> "
            "(uses default app)"
        )
    logger.info(
        "Inbound routing: %s",
        'DISABLED (forward-only mode)'
        if cfg.forward_only else 'ENABLED',
    )


def _run_bridge(cfg: BridgeConfig) -> None:
    """
    Start the HTTP bridge using the already-populated configuration.

    Called exactly once, from `main()`. From this point on, the
    bridge reads only from `cfg`.

    Behaviour depends on cfg.forward_only:

        * False (default): the LingoFuse Call APIs are registered,
          then a Flask HTTP listener is started on cfg.host:cfg.port
          and the function blocks inside Flask's app.run().

        * True: the LingoFuse Call APIs are registered, then the
          function blocks on a plain sleep loop. No socket is
          opened, no Flask worker is spawned. The process exits on
          KeyboardInterrupt (Ctrl+C) or SIGTERM, and cleanup() runs
          from the finally block.

    In both modes, the standard cleanup() path runs on exit and is
    idempotent thanks to the _cleanup_done flag.
    """
    _configure_logging(cfg)
    _log_startup_banner(cfg)

    if not _setup_network(cfg):
        sys.exit(1)

    # ------------------------------------------------------------------
    # Forward-only mode: no HTTP listener. The LingoFuse worker
    # threads service the registered Call APIs; the main Python
    # thread just sleeps until the process is asked to exit.
    #
    # We use a long time.sleep() rather than a busy loop or a
    # signal.pause(), so that:
    #   * Ctrl+C (KeyboardInterrupt) is delivered promptly on both
    #     POSIX and Windows,
    #   * the process consumes no CPU while idle,
    #   * atexit-registered cleanup still runs on normal interpreter
    #     exit.
    # ------------------------------------------------------------------
    if cfg.forward_only:
        logger.info(
            "Forward-only mode active: HTTP listener is DISABLED. "
            "Only the LingoFuse Call APIs will be served. "
            "Press Ctrl+C to exit."
        )
        try:
            while True:
                time.sleep(3600)
        except KeyboardInterrupt:
            logger.info("Interrupted, shutting down...")
        finally:
            cleanup()
        return

    # ------------------------------------------------------------------
    # Full mode: start the Flask HTTP listener.
    # ------------------------------------------------------------------
    logger.info(
        "Starting HTTP service: http://%s:%d", cfg.host, cfg.port,
    )
    logger.info("Press Ctrl+C to exit...")

    try:
        app.run(
            host=cfg.host,
            port=cfg.port,
            threaded=cfg.threaded,
            use_reloader=False,
        )
    except KeyboardInterrupt:
        logger.info("Interrupted, shutting down...")
    finally:
        cleanup()


# ======================================================================
# Entry point
# ======================================================================

def main() -> None:
    """
    Process entry point.

    This is the ONLY function in the module that touches the process
    environment or the raw command-line argument vector. It performs
    the two-phase configuration load (environment first, then
    command line) and hands control to `_run_bridge()`, which reads
    only the global configuration instance.

    A third, programmatic configuration layer is available to
    embedded callers: because `config` is a module-level object, any
    code that imports this module may assign to its fields BEFORE
    `main()` is called. `_apply_environment_defaults()` and
    `_apply_command_line()` only overwrite a field when the
    corresponding environment variable is set or the corresponding
    CLI flag is present, so a programmatic pre-set survives unless
    the operator explicitly overrides it.

    Running `python bridge.py --help` prints the full usage text
    (including the environment-variable reference) and exits with
    status 0. This is provided automatically by argparse.
    """
    _apply_environment_defaults(config)
    _apply_command_line(config, sys.argv[1:])
    _run_bridge(config)


if __name__ == '__main__':
    main()