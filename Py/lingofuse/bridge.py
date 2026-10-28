#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
LingoFuse HTTP Bridge - Bidirectional HTTP <-> LingoFuse POST gateway
with canonical JSON normalization and three-addressing-mode routing.

Direction A (inbound, HTTP -> LingoFuse):
    HTTP client POSTs to a routing URL; the bridge forwards the body to a
    LingoFuse target via the named API and returns the response.

Direction B (outbound, LingoFuse -> HTTP):
    A LingoFuse caller invokes __lf_outbound_post__ with a JSON request
    describing an HTTP POST; the bridge performs it and returns the result.

Direction C (repair, LingoFuse -> LingoFuse):
    A LingoFuse caller invokes __lf_repair_json__ with malformed JSON text;
    the bridge runs the unified repair engine and returns the repaired text.

Inbound routing:
    /<app>/<api>                App-name addressing (LOCAL-FIRST)
    /<api>                      App-name addressing, using --app
    /uid/<hex64>/<api>          UID addressing (LOCAL-FIRST)
    /p2p/<group>/<api>          P2PName addressing (NOT local-first)

The leading segments "uid" and "p2p" are reserved and always select the
corresponding addressing mode.

Operating modes:
    full          HTTP listener enabled; all three directions active.
    forward-only  HTTP listener disabled; only the Call APIs are served.

Configuration precedence:
    command line > environment variable > programmatic pre-set > defaults.
    The config object is frozen after main() populates it.

Error codes (inbound JSON error body):
    -1  Remote call failed (timeout / null handle / unexpected exception).
    -2  Request shape error (malformed URL path). HTTP 400.
    -3  API pre-check failed after retries.

All comments and log messages are in English.
"""

import argparse
import atexit
import codecs
import json
import logging
import os
import re
import shlex
import sys
import threading
import time
from dataclasses import dataclass
from typing import Optional, Tuple

import requests
from flask import Flask, request, Response

# ----------------------------------------------------------------------
# Import-path bootstrap: put the PACKAGE PARENT on sys.path so that
# `import lingofuse` resolves to THIS checkout, not a stale copy
# elsewhere on the inherited PYTHONPATH.
# ----------------------------------------------------------------------
_PACKAGE_PARENT = os.path.dirname(
    os.path.dirname(os.path.abspath(__file__))
)
# Always move the package parent to the FRONT of sys.path, even if it
# is already present. A stale copy of `lingofuse` earlier on the
# inherited PYTHONPATH would otherwise win the import race, and the
# resulting ImportError would name the OTHER copy's file path.
while _PACKAGE_PARENT in sys.path:
    sys.path.remove(_PACKAGE_PARENT)
sys.path.insert(0, _PACKAGE_PARENT)


from lingofuse import (
    set_option,
    check_api,
    get_status,
    get_status_num,
)
from lingofuse.errors import ConnectionError, TimeoutError, LingoFuseError
from lingofuse._lf_native import (
    LF_ResetPrepare,
    LF_PrepareClient,
    LF_PrepareDone,
    LF_Call,
    LF_UID_Call,
    LF_P2PNAME_Call,
    LF_FreeData,
    LF_CreateData,
    LF_ExitMainThread,
    LF_Shutdown,
    LF_CreateApp,
    LF_FreeApp,
    LF_RegisterCall,
    LF_SetPos,
    LFCallFunc,
)
from lingofuse.core import DataHandle
from lingofuse.address import _normalize_uid, _to_tp2p_uid
from lingofuse.options import set_opt_debug
from lingofuse.lf_io import (
    ENCODING,
    cstr,
    dumps_json,
    read_string_bytes,
    write_string_bytes,
)
from lingofuse.json_repair_preprocess import repair_json_text


# ======================================================================
# Defaults
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
DEFAULT_FORWARD_ONLY = False
DEFAULT_WAIT_CONNECTION = False
DEFAULT_WAIT_TIMEOUT_MS = 60000

ALLOWED_HTTP_METHODS = frozenset(
    ('GET', 'POST', 'PUT', 'PATCH', 'DELETE', 'HEAD', 'OPTIONS')
)

MAX_OUTBOUND_TIMEOUT_S = 300.0

RESERVED_PREFIX_UID = 'uid'
RESERVED_PREFIX_P2P = 'p2p'


# ======================================================================
# BridgeConfig
# ======================================================================
# Populated once by main(), then read-only for the rest of the process
# EXCEPT for the fields listed in _MUTABLE_FIELDS, which the interactive
# console may change at runtime.
# ======================================================================

@dataclass
class BridgeConfig:
    """Process-wide configuration."""

    host: str = DEFAULT_HOST
    port: int = DEFAULT_PORT
    threaded: bool = DEFAULT_THREADED

    forward_only: bool = DEFAULT_FORWARD_ONLY

    endpoint: str = DEFAULT_ENDPOINT
    timeout_ms: int = DEFAULT_TIMEOUT_MS
    default_app: Optional[str] = None
    no_precheck: bool = DEFAULT_NO_PRECHECK

    wait_connection: bool = DEFAULT_WAIT_CONNECTION
    wait_timeout_ms: int = DEFAULT_WAIT_TIMEOUT_MS

    normalize_json: bool = DEFAULT_NORMALIZE_JSON

    debug: bool = DEFAULT_DEBUG
    log_file: Optional[str] = DEFAULT_LOG_FILE

    bridge_app_name: str = DEFAULT_BRIDGE_APP_NAME
    bridge_api_name: str = DEFAULT_BRIDGE_API_NAME
    bridge_repair_api_name: str = DEFAULT_BRIDGE_REPAIR_API_NAME


config = BridgeConfig()


# ======================================================================
# Environment-variable table
# ======================================================================

_ENV_VAR_TABLE = {
    'host':                    'LINGOFUSE_HOST',
    'port':                    'LINGOFUSE_PORT',
    'endpoint':                'LINGOFUSE_ENDPOINT',
    'timeout_ms':              'LINGOFUSE_TIMEOUT',
    'default_app':             'LINGOFUSE_APP',
    'threaded':                'LINGOFUSE_THREADED',
    'forward_only':            'LINGOFUSE_FORWARD_ONLY',
    'wait_connection':         'LINGOFUSE_WAIT_CONNECTION',
    'wait_timeout_ms':         'LINGOFUSE_WAIT_TIMEOUT',
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

logger = logging.getLogger('LingoFuseBridge')
logger.setLevel(logging.INFO)

_formatter = logging.Formatter('[%(levelname)s] %(message)s')

_stderr_handler = logging.StreamHandler(sys.stderr)
_stderr_handler.setFormatter(_formatter)
logger.addHandler(_stderr_handler)


# ======================================================================
# Environment-variable readers
# ======================================================================

def _env_str(name: str) -> Optional[str]:
    """Read a raw string from the environment. None when unset."""
    if name in os.environ:
        return os.environ[name]
    return None


def _env_int(name: str) -> Optional[int]:
    """Read an int from the environment. None when unset or malformed."""
    raw = _env_str(name)
    if raw is None:
        return None
    try:
        return int(raw)
    except ValueError:
        logger.warning(
            "Environment variable %s=%r is not a valid integer; "
            "the default will be used",
            name, raw,
        )
        return None


def _env_bool(name: str) -> Optional[bool]:
    """Read a boolean from the environment. None when unset or malformed."""
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
    """Load defaults from the environment into `cfg`. Called once."""
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

    raw = _env_str(_ENV_VAR_TABLE['default_app'])
    if raw is not None:
        cfg.default_app = raw if raw else None

    value = _env_bool(_ENV_VAR_TABLE['threaded'])
    if value is not None:
        cfg.threaded = value

    value = _env_bool(_ENV_VAR_TABLE['forward_only'])
    if value is not None:
        cfg.forward_only = value

    value = _env_bool(_ENV_VAR_TABLE['wait_connection'])
    if value is not None:
        cfg.wait_connection = value

    value = _env_int(_ENV_VAR_TABLE['wait_timeout_ms'])
    if value is not None:
        cfg.wait_timeout_ms = value

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

    Each argparse default is the CURRENT value of the corresponding
    field, so argparse keeps the environment-derived value when the
    user does not pass the flag, and substitutes the user's value
    when the flag is present.
    """
    parser = argparse.ArgumentParser(
        prog='bridge',
        description=(
            "LingoFuse HTTP Bridge - bidirectional HTTP <-> LingoFuse "
            "POST gateway with canonical JSON normalization, "
            "three-addressing-mode routing (App name / UID / P2PName), "
            "and a LingoFuse-callable JSON repair API. "
            "Environment variables are read as defaults; command-line "
            "arguments override them."
        ),
        epilog=(
            "Inbound routing: /<app>/<api>, /<api>, /uid/<hex64>/<api>, "
            "/p2p/<group>/<api>. "
            "Environment variables: "
            "LINGOFUSE_HOST, LINGOFUSE_PORT, LINGOFUSE_ENDPOINT, "
            "LINGOFUSE_TIMEOUT, LINGOFUSE_APP, LINGOFUSE_THREADED, "
            "LINGOFUSE_FORWARD_ONLY, LINGOFUSE_WAIT_CONNECTION, "
            "LINGOFUSE_WAIT_TIMEOUT, LINGOFUSE_DEBUG, "
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
            "proxy and JSON repair). No TCP port is opened."
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

    # --- connection readiness ---
    parser.add_argument(
        '--wait-connection',
        dest='wait_connection',
        action='store_true',
        default=cfg.wait_connection,
        help=(
            "Block in LF_PrepareDone until the LingoFuse client-"
            "server handshake is complete. This eliminates the "
            "first-request race against the broadcast cache at the "
            "cost of a bounded startup delay (bounded by "
            "--wait-timeout). Not the default; see "
            "--no-wait-connection."
        ),
    )
    parser.add_argument(
        '--no-wait-connection',
        dest='wait_connection',
        action='store_false',
        help=(
            "Do NOT block in LF_PrepareDone (default). The HTTP "
            "listener starts immediately, but the first requests may "
            "fail with a -3 pre-check error until the broadcast cache "
            "catches up (typically 1-3 seconds)."
        ),
    )
    parser.add_argument(
        '--wait-timeout',
        dest='wait_timeout_ms',
        type=int,
        default=cfg.wait_timeout_ms,
        help=(
            f"Maximum time, in milliseconds, to wait for the "
            f"handshake when --wait-connection is enabled "
            f"(default: {cfg.wait_timeout_ms}). Note that "
            f"LF_PrepareDone still returns 1 when the timeout expires "
            f"without the client being ready; the bridge will warn "
            f"at startup and proceed."
        ),
    )

    # --- Boolean flags ---
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
            "Disable the inbound API pre-check (check_api / "
            "check_uid_api / check_p2pname_api) to avoid cache false "
            "negatives. Ignored in forward-only mode."
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
            "and re-emit as compact UTF-8 JSON (default)."
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
            f"(default: {cfg.bridge_repair_api_name})."
        ),
    )

    args = parser.parse_args(argv)

    cfg.host = args.host
    cfg.port = args.port
    cfg.forward_only = args.forward_only
    cfg.endpoint = args.endpoint
    cfg.timeout_ms = args.timeout_ms
    cfg.default_app = args.default_app if args.default_app else None
    cfg.wait_connection = args.wait_connection
    cfg.wait_timeout_ms = args.wait_timeout_ms
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
    """Configure the module logger. Called once from _run_bridge()."""
    if cfg.debug:
        logger.setLevel(logging.DEBUG)
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

_bridge_app_handle = None
_bridge_app_callbacks = []


# ======================================================================
# JSON normalization (inbound path)
# ======================================================================

_TRAILING_COMMA_RE = re.compile(r',(\s*[}\]])')

_BOM_UTF8 = codecs.BOM_UTF8
_BOM_UTF16_LE = codecs.BOM_UTF16_LE
_BOM_UTF16_BE = codecs.BOM_UTF16_BE

STATUS_PASSTHROUGH = 'passthrough'
STATUS_CANONICAL = 'canonical'
STATUS_REPAIRED = 'repaired'
STATUS_RECODED = 'recoded'

_RESPONSE_CONTENT_TYPES = {
    STATUS_CANONICAL: 'application/json; charset=utf-8',
    STATUS_REPAIRED: 'application/json; charset=utf-8',
    STATUS_RECODED: 'application/json; charset=utf-8',
    STATUS_PASSTHROUGH: 'application/octet-stream',
}


def _try_repair_json(text: str) -> Optional[str]:
    """Layer 1 of the repair stack: conservative in-module repairs."""
    s = text.strip()
    if not s:
        return None

    if s.startswith('\ufeff'):
        s = s[1:].lstrip()
        if not s:
            return None

    if s[0] not in '{["-0123456789tfn':
        return None

    return _TRAILING_COMMA_RE.sub(r'\1', s)


def normalize_json_bytes(raw: bytes) -> Tuple[bytes, str]:
    """
    Normalize a byte payload into canonical UTF-8 JSON.

    Returns (normalized_bytes, status). Binary safety is a hard
    requirement: a payload that is not JSON even after both repair
    layers is returned UNCHANGED with status passthrough.
    """
    if not raw:
        return raw, STATUS_PASSTHROUGH

    original = raw

    if raw.startswith(_BOM_UTF8):
        raw = raw[len(_BOM_UTF8):]
    elif raw.startswith(_BOM_UTF16_LE) or raw.startswith(_BOM_UTF16_BE):
        return original, STATUS_PASSTHROUGH

    if raw.endswith(b'\x00'):
        raw = raw.rstrip(b'\x00')
    if not raw:
        return original, STATUS_PASSTHROUGH

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
        return original, STATUS_PASSTHROUGH

    obj = None
    parsed = False
    try:
        obj = json.loads(text)
        parsed = True
    except json.JSONDecodeError:
        pass

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
                pass

    if not parsed:
        return original, STATUS_PASSTHROUGH

    canonical_str = dumps_json(obj)
    canonical_bytes = canonical_str.encode(ENCODING, errors="replace")

    if repaired_flag:
        return canonical_bytes, STATUS_REPAIRED
    if encoding_used != ENCODING:
        return canonical_bytes, STATUS_RECODED
    return canonical_bytes, STATUS_CANONICAL


# ======================================================================
# Flask application
# ======================================================================

app = Flask(__name__)
app.logger.disabled = True
logging.getLogger('werkzeug').setLevel(logging.ERROR)


@app.after_request
def _after_request(response: Response) -> Response:
    """Attach permissive CORS headers. Never fails the response."""
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

_cleanup_done = False
_cleanup_lock = threading.Lock()


def cleanup() -> None:
    """
    Stop the LingoFuse main thread and shut down the library.

    Order: clear network events, stop the main thread, free the App,
    release callbacks, unload the library. Idempotent and thread-safe.
    """
    global _cleanup_done, _bridge_app_handle, _bridge_app_callbacks
    with _cleanup_lock:
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

    # Detach every handler BEFORE the final log call: during
    # interpreter teardown sys.stderr may already be closed, and a
    # logger call in that state emits a "--- Logging error ---" banner
    # from inside the handler's emit() rather than raising to us.
    for _handler in list(logger.handlers):
        try:
            logger.removeHandler(_handler)
            _handler.close()
        except Exception:
            pass

    try:
        logger.info("LingoFuse resources released")
    except Exception:
        pass


atexit.register(cleanup)


# ======================================================================
# Helpers
# ======================================================================

def _json_error_response(code: int, msg: str,
                         http_status: int = 200) -> Response:
    """Build a JSON error response with the canonical encoding policy."""
    body = dumps_json({"code": code, "error": msg}).encode(
        ENCODING, errors="replace",
    )
    return app.response_class(
        response=body,
        status=http_status,
        mimetype='application/json; charset=utf-8',
    )


def _drain_status(n: int = 3) -> None:
    """Drain up to `n` pending status messages into the bridge logger."""
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
    """Decode bytes via UTF-8 -> GBK -> Latin-1. Returns (text, encoding)."""
    for candidate in (ENCODING, 'gbk', 'latin-1'):
        try:
            return raw.decode(candidate), candidate
        except (UnicodeDecodeError, LookupError):
            continue
    return None, ENCODING


# ======================================================================
# URL routing parser
# ======================================================================

def _parse_inbound_path(path: str) -> Tuple[str, object, str]:
    """
    Parse the inbound URL path into (mode, key, api_name).

    Modes:
        "app"  -> key is the app name as a str, or None when the
                  default app should be used.
        "uid"  -> key is a 32-byte bytes object.
        "p2p"  -> key is the P2P group name as a str.

    Raises ValueError on a malformed path.
    """
    stripped = path.strip('/')
    if not stripped:
        raise ValueError("Empty path")

    parts = stripped.split('/')

    if parts[0] == RESERVED_PREFIX_UID:
        if len(parts) < 3:
            raise ValueError(
                f"UID route requires /{RESERVED_PREFIX_UID}/"
                f"<hex64>/<api>; got /{stripped}"
            )
        uid_hex = parts[1]
        api_name = '/'.join(parts[2:])
        if not api_name:
            raise ValueError("UID route is missing the API name")
        try:
            uid_bytes = _normalize_uid(uid_hex)
        except (ValueError, TypeError) as exc:
            raise ValueError(
                f"Invalid UID in path: {exc}"
            ) from exc
        return "uid", uid_bytes, api_name

    if parts[0] == RESERVED_PREFIX_P2P:
        if len(parts) < 3:
            raise ValueError(
                f"P2PName route requires /{RESERVED_PREFIX_P2P}/"
                f"<group>/<api>; got /{stripped}"
            )
        group_name = parts[1]
        api_name = '/'.join(parts[2:])
        if not group_name:
            raise ValueError("P2PName route is missing the group name")
        if not api_name:
            raise ValueError("P2PName route is missing the API name")
        return "p2p", group_name, api_name

    if len(parts) == 1:
        return "app", None, parts[0]

    app_name = parts[0]
    api_name = '/'.join(parts[1:])
    if not api_name:
        raise ValueError("App route is missing the API name")
    return "app", app_name, api_name


def _precheck_inbound(mode: str, key: object, api_name: str) -> bool:
    """
    Run the addressing-mode-specific pre-check with retry.

    Consults a locally cached view of the mesh updated by periodic
    broadcasts, which lags fresh registrations by a few seconds.
    Retries 3 times (200 ms apart) before giving up. With
    --wait-connection the cache is already populated at startup;
    otherwise the retry loop is the caller's only protection against
    the ~3-second broadcast delay.
    """
    from lingofuse import check_uid_api, check_p2pname_api

    for attempt in range(3):
        if mode == "app":
            ok = check_api(key, api_name)
        elif mode == "uid":
            ok = check_uid_api(key, api_name)
        elif mode == "p2p":
            ok = check_p2pname_api(key, api_name)
        else:
            ok = False

        if ok:
            return True
        if config.debug:
            logger.debug(
                "precheck(%s, %r, %s) attempt %d returned False",
                mode, key, api_name, attempt + 1,
            )
        time.sleep(0.2)

    return False


# ======================================================================
# Outbound LingoFuse Call API: HTTP POST proxy
# ======================================================================

def _normalize_headers_dict(headers) -> dict:
    """Return a plain dict with lower-cased header names."""
    if headers is None:
        return {}
    try:
        items = headers.items()
    except AttributeError:
        return {"_raw": str(headers)}
    return {str(k).lower(): str(v) for k, v in items}


def _parse_outbound_request(req) -> Tuple[Optional[dict], Optional[str]]:
    """Validate the JSON request object. Returns (parsed, error_message)."""
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

    Runs on a LingoFuse worker thread. Must not call any blocking
    LingoFuse function. All exceptions are caught and converted into
    a JSON error response written to the output handle.
    """
    h_in = DataHandle._from_raw(inp, owned=False)
    h_out = DataHandle._from_raw(out, owned=False)

    try:
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

        # Serialize the body ourselves with dumps_json(), NOT with
        # requests' json= shortcut: that shortcut uses
        # ensure_ascii=True and would escape every non-ASCII character.
        if body_obj is None:
            body_bytes = None
        else:
            body_bytes = dumps_json(body_obj).encode(
                ENCODING, errors="replace",
            )
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

        resp = requests.request(
            method=method,
            url=url,
            headers=headers,
            data=body_bytes,
            timeout=timeout,
        )

        try:
            resp_body = resp.json()
        except ValueError:
            resp_body = resp.content.decode(ENCODING, errors='replace')

        result = {
            "status_code": resp.status_code,
            "headers": _normalize_headers_dict(resp.headers),
            "body": resp_body,
        }

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
        logger.exception("Unexpected error in outbound POST callback")
        try:
            h_out.write_json({"error": f"Internal error: {e}"})
        except Exception:
            pass


# ======================================================================
# LingoFuse Call API: JSON repair service
# ======================================================================

def _bridge_repair_callback(trigger, inp, out):
    """
    LingoFuse Call API callback: repairs a malformed JSON string.

    Input: UTF-8 (or GBK / Latin-1) JSON text, possibly malformed,
    possibly NUL-terminated. Output: UTF-8 NUL-terminated text.

    Binary safety: an undecodable payload is returned unchanged; an
    unrepairable text is returned unchanged. No exception escapes
    into the C stack.
    """
    h_out = DataHandle._from_raw(out, owned=False)

    try:
        raw = read_string_bytes(inp)

        if not raw:
            write_string_bytes(out, b"")
            return

        if raw.startswith(_BOM_UTF8):
            raw = raw[len(_BOM_UTF8):]
        elif raw.startswith(_BOM_UTF16_LE) or raw.startswith(_BOM_UTF16_BE):
            write_string_bytes(out, raw)
            return

        if raw.endswith(b'\x00'):
            raw = raw.rstrip(b'\x00')
        if not raw:
            write_string_bytes(out, b"")
            return

        text, _encoding_used = _decode_text_with_fallback(raw)
        if text is None:
            write_string_bytes(out, raw)
            return

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

        write_string_bytes(
            out,
            repaired.encode(ENCODING, errors="replace"),
        )

    except Exception:
        logger.exception("Unexpected error in JSON repair callback")
        try:
            write_string_bytes(out, b"")
        except Exception:
            pass


# ======================================================================
# Inbound HTTP request handler
# ======================================================================

@app.route('/', defaults={'path': ''}, methods=['POST', 'OPTIONS'])
@app.route('/<path:path>', methods=['POST', 'OPTIONS'])
def handle_call(path: str):
    """Handle an inbound HTTP request and forward it to LingoFuse."""
    if request.method == 'OPTIONS':
        return '', 200

    try:
        mode, key, api_name = _parse_inbound_path(path)
    except ValueError as e:
        return _json_error_response(-2, str(e), 400)

    if mode == "app" and key is None:
        if not config.default_app:
            return _json_error_response(
                -2,
                "No default app configured (use --app or "
                "LINGOFUSE_APP, or include the app name in the path)",
                400,
            )
        key = config.default_app

    if not config.no_precheck:
        if not _precheck_inbound(mode, key, api_name):
            if config.debug:
                logger.debug(
                    "precheck(%s, %r, %s) failed after retries",
                    mode, key, api_name,
                )
                _drain_status(3)
            return _json_error_response(
                -3,
                f"API '{api_name}' not available for "
                f"{mode} target {key!r}",
                200,
            )

    body = request.get_data()

    request_status = STATUS_PASSTHROUGH
    if config.normalize_json:
        body, request_status = normalize_json_bytes(body)

    if config.debug:
        logger.debug(
            "Inbound request: mode=%s key=%r api=%s bytes=%d "
            "normalize=%s status=%s",
            mode, key, api_name, len(body),
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

    try:
        hnd_in = LF_CreateData(cstr(api_name))
        if not hnd_in:
            raise LingoFuseError("Failed to create DataHandle")

        try:
            write_string_bytes(hnd_in, body)

            # Use the SYNCHRONOUS family on the inbound path.
            # The synchronous family returns a caller-owned handle;
            # the asynchronous family's Result_ handle is owned by the
            # framework and is released the moment its callback
            # returns, so retaining it across threads is a
            # use-after-free and freeing it is a double-free.
            if mode == "uid":
                uid_arr = _to_tp2p_uid(key)
                res_ptr = LF_UID_Call(
                    uid_arr, hnd_in, config.timeout_ms
                )
            elif mode == "p2p":
                res_ptr = LF_P2PNAME_Call(
                    cstr(key), hnd_in, config.timeout_ms
                )
            else:
                res_ptr = LF_Call(
                    cstr(key), hnd_in, config.timeout_ms
                )
        finally:
            LF_FreeData(hnd_in)

        if not res_ptr:
            raise LingoFuseError("Remote call returned a null handle")

        try:
            # The synchronous primitive delivers the handle with the
            # write cursor at the end; reset it before reading.
            LF_SetPos(res_ptr, 0)
            result_bytes = read_string_bytes(res_ptr)
        finally:
            # Caller-owned handle: freeing it here is correct.
            LF_FreeData(res_ptr)

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
    register the bridge's own two Call APIs.

    On success, populates _bridge_app_handle and _bridge_app_callbacks.
    On failure, releases any partially-created resource and returns
    False.
    """
    global _bridge_app_handle, _bridge_app_callbacks

    app_handle = None
    c_post_callback = None
    c_repair_callback = None

    try:
        # 1. Connection readiness.
        if cfg.wait_connection:
            set_option("Wait_Connection_ReadyOk", "True")
            set_option("Wait_Connection_Timeout",
                       str(cfg.wait_timeout_ms))
            logger.info(
                "Connection readiness: WAIT (timeout=%d ms)",
                cfg.wait_timeout_ms,
            )
        else:
            set_option("Wait_Connection_ReadyOk", "False")
            logger.info(
                "Connection readiness: DO NOT WAIT "
                "(early requests may fail with a -3 pre-check error)"
            )

        # 2. Reset any leftover preparation state.
        LF_ResetPrepare()

        # 3. Create the bridge's own App.
        app_handle = LF_CreateApp(
            cstr(cfg.bridge_app_name),
            cstr("LingoFuse HTTP Bridge - outbound POST proxy and "
                 "JSON repair service"),
        )
        if not app_handle:
            raise ConnectionError(
                f"Failed to create bridge App '{cfg.bridge_app_name}'"
            )

        # 4a. Register the outbound POST API.
        # The ctypes callback object must stay alive for as long as
        # the library holds its function pointer.
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

        # 4b. Register the JSON repair API.
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

        # 5. Prepare the client with the bridge's App handle.
        # Overlap_Connection lets the bridge coexist with an existing
        # client on the same endpoint (for example, a legacy bridge).
        set_option("Overlap_Connection", "True")

        ret = LF_PrepareClient(cstr(cfg.endpoint), app_handle)
        if ret == -1:
            raise ConnectionError(
                f"LF_PrepareClient returned -1 for endpoint "
                f"'{cfg.endpoint}'. Address may already be in use by "
                f"a client that does not allow overlap."
            )

        # 6. Start the LingoFuse main thread. LF_PrepareDone still
        # returns 1 on a handshake timeout, so we treat only a
        # non-1 return as a hard failure.
        ret = LF_PrepareDone()
        if ret != 1:
            raise ConnectionError(f"LF_PrepareDone returned {ret}")

        # 6b. Post-startup readiness confirmation (diagnostic only).
        if cfg.wait_connection:
            try:
                own_api_visible = check_api(
                    cfg.bridge_app_name, cfg.bridge_api_name
                )
            except Exception:
                own_api_visible = False
            if own_api_visible:
                logger.info(
                    "Connection readiness confirmed: bridge API "
                    "'%s.%s' is visible on the local cache.",
                    cfg.bridge_app_name, cfg.bridge_api_name,
                )
            else:
                logger.warning(
                    "Connection readiness was requested but the "
                    "bridge API '%s.%s' is not yet visible on the "
                    "local cache. The handshake may have timed out "
                    "(%d ms). Early inbound requests may fail with a "
                    "-3 pre-check error until the broadcast "
                    "completes.",
                    cfg.bridge_app_name, cfg.bridge_api_name,
                    cfg.wait_timeout_ms,
                )

        # 7. Publish the globals.
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
# Interactive console
# ======================================================================
# Available only when stdin is a TTY. A single daemon thread reads
# commands. Writes to mutable fields take _config_lock; hot-path reads
# are lock-free (single-attribute reads under the GIL).
#
# Mutable fields are limited to those read per-request and not backed
# by a resource that is already bound (Flask socket, LingoFuse client,
# registered App/APIs, log file handler) or meaningful only at startup.
# ======================================================================

_console_stop_event = threading.Event()
_console_thread: Optional[threading.Thread] = None
_config_lock = threading.RLock()

_MUTABLE_FIELDS = {
    'timeout_ms':     'int > 0',
    'debug':          'bool',
    'no_precheck':    'bool',
    'normalize_json': 'bool',
    'default_app':    'str (empty to clear)',
}


def _parse_bool(value: str) -> bool:
    """Parse a boolean console argument. Raises ValueError on garbage."""
    v = value.strip().lower()
    if v in ('1', 'true', 'yes', 'on'):
        return True
    if v in ('0', 'false', 'no', 'off'):
        return False
    raise ValueError(
        f"expected one of true/false, 1/0, yes/no, on/off; got {value!r}"
    )


def _console_cmd_help(_cfg: BridgeConfig) -> str:
    return "\n".join([
        "Available commands:",
        "  help / ? / h                 show this help",
        "  status / show / info         show current configuration",
        "  set <key> <value>            change a mutable field",
        "  debug:<text>                 dispatch a C4 console command",
        "                               (forwarded verbatim to",
        "                               lingofuse.options.set_opt_debug)",
        "  quit / exit / q              stop the bridge and exit",
        "",
        "Mutable fields (set <key> <value>):",
        "  timeout_ms      int > 0      LingoFuse call timeout, ms",
        "  debug           bool         verbose logging in this module",
        "  no_precheck     bool         skip the inbound API pre-check",
        "  normalize_json  bool         enable JSON normalization",
        "  default_app     str          default target app for short URLs",
        "                               (empty string clears it)",
        "",
        "All other startup fields are frozen after startup; 'status'",
        "reports the full list.",
    ])


def _console_cmd_status(cfg: BridgeConfig) -> str:
    mode = 'forward-only' if cfg.forward_only else 'full'
    listen = (
        'disabled'
        if cfg.forward_only
        else f'http://{cfg.host}:{cfg.port}'
    )
    return "\n".join([
        "=== Bridge configuration ===",
        f"  operating mode     : {mode}",
        f"  HTTP listener      : {listen}",
        f"  LingoFuse endpoint : {cfg.endpoint}",
        f"  bridge app         : {cfg.bridge_app_name}",
        f"  outbound POST API  : {cfg.bridge_api_name}",
        f"  repair API         : {cfg.bridge_repair_api_name}",
        f"  default app        : {cfg.default_app or '(none)'}",
        f"  call timeout       : {cfg.timeout_ms} ms",
        f"  threaded           : {cfg.threaded}",
        f"  debug              : {cfg.debug}",
        f"  no_precheck        : {cfg.no_precheck}",
        f"  normalize_json     : {cfg.normalize_json}",
        f"  wait_connection    : {cfg.wait_connection}",
        f"  wait_timeout_ms    : {cfg.wait_timeout_ms}",
        f"  log_file           : {cfg.log_file or '(stderr only)'}",
        "",
        f"Mutable at runtime  : {', '.join(sorted(_MUTABLE_FIELDS))}",
        "Frozen after startup: host, port, forward_only, endpoint,",
        "                      wait_connection, wait_timeout_ms,",
        "                      threaded, log_file, bridge_app_name,",
        "                      bridge_api_name, bridge_repair_api_name",
    ])


def _console_cmd_set(cfg: BridgeConfig, tokens) -> str:
    if len(tokens) < 3:
        return "usage: set <key> <value>   (use \"\" for an empty string)"
    key = tokens[1]
    value = ' '.join(tokens[2:])
    if key not in _MUTABLE_FIELDS:
        return (
            f"'{key}' cannot be changed at runtime "
            f"(frozen after startup); try 'status' for the full list"
        )
    try:
        if key == 'timeout_ms':
            n = int(value)
            if n <= 0:
                raise ValueError("must be a positive integer")
            with _config_lock:
                setattr(cfg, key, n)
        elif key in ('debug', 'no_precheck', 'normalize_json'):
            b = _parse_bool(value)
            with _config_lock:
                setattr(cfg, key, b)
        elif key == 'default_app':
            with _config_lock:
                setattr(cfg, key, value if value else None)
        else:
            return f"internal error: no handler for '{key}'"
    except (ValueError, TypeError) as e:
        return f"invalid value for {key!r}: {e}"
    return f"{key} = {getattr(cfg, key)!r}"


def _console_cmd_debug(_cfg: BridgeConfig, payload: str) -> str:
    # Forward verbatim: the payload is free-form text (spaces allowed)
    # and is not shlex-split.
    payload = payload.strip()
    if not payload:
        return (
            "usage: debug:<c4-console-command>   "
            "(e.g. debug:service, debug:tunnel, debug:HPC_Thread_Info)"
        )
    try:
        set_opt_debug(payload)
    except Exception as e:
        logger.exception("set_opt_debug(%r) failed", payload)
        return f"set_opt_debug failed: {e}"
    return f"debug command dispatched: {payload!r}"


def _console_cmd_quit(_cfg: BridgeConfig) -> None:
    """
    Best-effort shutdown, then unconditional exit.

    Flask's app.run() blocks on the main thread and cannot be
    interrupted portably from another thread, so os._exit() is the
    only reliable way to return control to the shell. cleanup() has
    already run above; _cleanup_done prevents any second invocation
    (including the atexit hook).
    """
    _console_stop_event.set()
    print("Shutting down...", flush=True)
    try:
        cleanup()
    except Exception:
        logger.exception("cleanup() failed during console quit")
    try:
        sys.stdout.flush()
        sys.stderr.flush()
    except Exception:
        pass
    os._exit(0)


def _dispatch_console_command(
    cfg: BridgeConfig, line: str
) -> Optional[str]:
    """Parse and execute one console command line. Returns the reply."""
    line = line.strip()
    if not line:
        return None

    if line.lower().startswith('debug:'):
        return _console_cmd_debug(cfg, line[len('debug:'):])

    try:
        tokens = shlex.split(line)
    except ValueError as e:
        return f"parse error: {e}"
    if not tokens:
        return None

    cmd = tokens[0].lower()
    if cmd in ('help', '?', 'h'):
        return _console_cmd_help(cfg)
    if cmd in ('status', 'show', 'info'):
        return _console_cmd_status(cfg)
    if cmd == 'set':
        return _console_cmd_set(cfg, tokens)
    if cmd in ('quit', 'exit', 'q'):
        _console_cmd_quit(cfg)
        return None
    return f"unknown command: {tokens[0]!r}; type 'help' for the list"


def _console_loop(cfg: BridgeConfig) -> None:
    """
    Read commands from stdin until EOF or the stop event.

    Responses go to stdout (not the logger) so that the operator sees
    them on the same terminal even when --log-file redirects the log
    stream.
    """
    while not _console_stop_event.is_set():
        try:
            line = sys.stdin.readline()
        except (EOFError, KeyboardInterrupt):
            break
        if line == '':
            logger.info("Console: EOF on stdin, command reader exiting")
            break
        if _console_stop_event.is_set():
            break
        response = _dispatch_console_command(cfg, line)
        if response:
            try:
                print(response, flush=True)
            except Exception:
                logger.exception("Console: failed to write response")


def _start_console(cfg: BridgeConfig) -> None:
    """
    Start the interactive command reader if stdin is a TTY.

    In non-interactive environments (systemd, Docker without -it, CI
    runners) stdin is not a TTY; readline would block forever or
    return EOF immediately, so the console is skipped and the bridge
    runs headless.
    """
    global _console_thread
    if not sys.stdin.isatty():
        logger.info("Console: stdin is not a TTY, command reader disabled")
        return
    print(
        "Interactive console ready. Type 'help' for commands, "
        "'quit' to exit.",
        flush=True,
    )
    _console_thread = threading.Thread(
        target=_console_loop,
        args=(cfg,),
        name="LingoFuseBridgeConsole",
        daemon=True,
    )
    _console_thread.start()
    logger.info("Console: interactive command reader started")


# ======================================================================
# Startup banner and main loop
# ======================================================================

def _log_startup_banner(cfg: BridgeConfig) -> None:
    """Print the effective configuration once, at startup."""
    logger.info("=== LingoFuse HTTP Bridge (bidirectional POST gateway "
                "with three-addressing routing and JSON repair service) ===")
    logger.info(
        "Operating mode: %s",
        'FORWARD-ONLY (HTTP listener disabled)'
        if cfg.forward_only else 'FULL (HTTP listener enabled)',
    )
    if cfg.forward_only:
        logger.info("Inbound HTTP listen: DISABLED (forward-only mode)")
    else:
        logger.info("Inbound HTTP listen: http://%s:%d", cfg.host, cfg.port)
    logger.info("LingoFuse endpoint: %s", cfg.endpoint)
    logger.info(
        "Inbound default app: %s",
        cfg.default_app or '(must be specified in URL path)',
    )
    logger.info("Inbound call timeout: %dms", cfg.timeout_ms)
    logger.info(
        "Connection readiness: %s",
        f'WAIT (timeout={cfg.wait_timeout_ms} ms)'
        if cfg.wait_connection else 'DO NOT WAIT',
    )
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
            "Inbound routes: /<app>/<api>, /<api>, "
            "/uid/<hex64>/<api>, /p2p/<group>/<api>"
        )
        logger.info(
            "Reserved URL segments: '%s' (UID), '%s' (P2PName)",
            RESERVED_PREFIX_UID, RESERVED_PREFIX_P2P,
        )


def _run_bridge(cfg: BridgeConfig) -> None:
    """
    Start the HTTP bridge using the already-populated configuration.

    The interactive console (if stdin is a TTY) is started only AFTER
    the network setup succeeds, so a failed LingoFuse connection exits
    the process immediately rather than dropping the operator into a
    command prompt on a dead bridge.
    """
    _configure_logging(cfg)
    _log_startup_banner(cfg)

    if not _setup_network(cfg):
        sys.exit(1)

    _start_console(cfg)

    if cfg.forward_only:
        logger.info(
            "Forward-only mode active: HTTP listener is DISABLED. "
            "Only the LingoFuse Call APIs will be served. "
            "Press Ctrl+C to exit."
        )
        try:
            while not _console_stop_event.wait(timeout=1.0):
                pass
        except KeyboardInterrupt:
            logger.info("Interrupted, shutting down...")
        finally:
            cleanup()
        return

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

    The ONLY function in the module that touches the process
    environment or the raw command-line argument vector. Performs the
    two-phase configuration load (environment first, then command
    line) and hands control to _run_bridge().

    A third, programmatic configuration layer is available: because
    `config` is a module-level object, code that imports this module
    may assign to its fields BEFORE main() is called. The two loaders
    only overwrite a field when the corresponding environment
    variable is set or the corresponding CLI flag is present.
    """
    _apply_environment_defaults(config)
    _apply_command_line(config, sys.argv[1:])
    _run_bridge(config)


if __name__ == '__main__':
    main()