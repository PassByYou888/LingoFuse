#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
LingoFuse HTTP Bridge - Generic Binary Passthrough Gateway

This bridge acts as a stateless middleware that forwards HTTP POST
requests directly to a LingoFuse backend. It does NOT interpret or
modify the request body; it simply passes the raw binary payload to
the target API and returns the raw response.

==================== REQUEST FORMAT ====================
POST /<app_name>/<api_name>
Content-Type: any (ignored by bridge, but preserved for backend)
Body: arbitrary binary data (will be sent as-is to the remote API)

If only one path segment is given (e.g., /api_name), the default app
(specified via --app) is used. If no default app is set, an error is
returned.

==================== RESPONSE FORMAT ====================
Success: HTTP 200 with the raw response body from the remote call,
         with any trailing null byte (0x00) stripped to avoid JSON
         parse issues in HTTP clients.
Failure (bridge-level errors): HTTP 200 with a JSON error object:
    {"code": -1, "error": "..."}     # call error (timeout, etc.)
    {"code": -2, "error": "..."}     # request format error (HTTP 400)
    {"code": -3, "error": "..."}     # check_api pre-check failed

==================== USAGE EXAMPLES ====================
# Start the bridge
python bridge.py --endpoint ipc:compute_grid --app pas --debug --port 8081

# Call with explicit app (path: /<app>/<api>)
curl -X POST http://127.0.0.1:8081/pas/exp -d '{"args":["1+2*3"]}'

# Call using default app (path: /<api>)
curl -X POST http://127.0.0.1:8081/exp -d '{"args":["1+2*3"]}'

==================== COMMAND-LINE ARGUMENTS ====================
--host        Listening address (default 0.0.0.0)
--port        Listening port (default 8081)
--endpoint    LingoFuse service endpoint (default ipc:lingofuse_bridge)
--timeout     Global call timeout in milliseconds (default 5000)
--app         Default target application name (used when the path has
              only an API name)
--threaded    Enable multi-threaded request handling (default)
--no-threaded Disable multi-threaded request handling
--debug       Enable debug logging of request/response details
--log-file    Path to log file (default: stderr)
--no-precheck Disable API pre-check (check_api) to avoid cache false
              negatives

==================== DEPENDENCIES ====================
- lingofuse package (must be on PYTHONPATH)
- Flask

==================== WIRE FORMAT POLICY ====================
The JSON serialization policy, the NUL termination convention, and
the c_char_p parameter encoding used by this file are ALL delegated
to lingofuse.lf_io. This file no longer carries its own local copy
of those helpers.

lingofuse.lf_io is the single source of truth for the LingoFuse
toolchain on the Python side. It guarantees:

  * Every JSON payload is serialized with ensure_ascii=False, so
    non-ASCII content (Chinese, emoji, accented Latin letters) is
    emitted as literal UTF-8 bytes. No \\uXXXX escape ever appears on
    the wire.

  * Every string written to a DataHandle is NUL-terminated, matching
    Pascal's LF_ReadString (see lingofuse_import.pas).

  * Every string read from a DataHandle stops at the first NUL, and
    tolerates a missing NUL by consuming the remainder of the buffer.
    This accepts payloads produced by non-Pascal producers.

  * Every c_char_p parameter of an LF_* function is passed NUL-
    terminated UTF-8 bytes via cstr(), instead of relying on the
    hidden NUL inside CPython bytes objects.

Historical note: this file used to carry its own local copy of the
I/O helpers, on the rationale of "avoiding a cross-package dependency
between lingofuse and llm_common". With the relocation of lf_io from
llm_common into the lingofuse package, that rationale no longer
holds: both modules now belong to the same package, and reusing
lf_io directly is the correct choice.
"""

import argparse
import atexit
import logging
import os
import sys
import time
from dataclasses import dataclass
from typing import Optional

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
)

# ----------------------------------------------------------------------
# Unified LingoFuse payload I/O
# ----------------------------------------------------------------------
#
# Every JSON serialization, NUL framing operation, and c_char_p
# parameter encoding in this file goes through lingofuse.lf_io, the
# single source of truth for the toolchain's wire format policy.
#
# Functions used here:
#     cstr               - NUL-terminated UTF-8 bytes for c_char_p args
#     dumps_json         - toolchain-wide JSON serialization policy
#     write_string_bytes - write raw bytes followed by a NUL terminator
#     read_string_bytes  - read up to the first NUL (or the whole
#                          buffer when no NUL is present)
from lingofuse.lf_io import (
    cstr,
    dumps_json,
    read_string_bytes,
    write_string_bytes,
)


# ======================================================================
# Defaults
# ======================================================================

DEFAULT_HOST = '0.0.0.0'
DEFAULT_PORT = 8081
DEFAULT_ENDPOINT = 'ipc:lingofuse_bridge'
DEFAULT_TIMEOUT = 5000
DEFAULT_THREADED = True
DEFAULT_DEBUG = False


# ======================================================================
# Configuration
# ----------------------------------------------------------------------
# The bridge is a process-wide singleton in practice (it drives a single
# LingoFuse connection and a single Flask instance). Instead of
# scattering the configuration across a handful of module-level global
# variables, we keep everything in a single dataclass instance. This
# removes the need for a `global` statement in the request handler and
# makes it easy to inspect the active configuration from a debugger.
# ======================================================================

@dataclass
class BridgeConfig:
    host: str = DEFAULT_HOST
    port: int = DEFAULT_PORT
    endpoint: str = DEFAULT_ENDPOINT
    timeout_ms: int = DEFAULT_TIMEOUT
    default_app: Optional[str] = None
    threaded: bool = DEFAULT_THREADED
    debug: bool = DEFAULT_DEBUG
    no_precheck: bool = False
    log_file: Optional[str] = None


# The active configuration is stored in this module-level instance.
# It is populated by `run_bridge()` before Flask starts serving.
config = BridgeConfig()


# ======================================================================
# Logging
# ======================================================================

logger = logging.getLogger('LingoFuseBridge')
logger.setLevel(logging.INFO)
_formatter = logging.Formatter('[%(levelname)s] %(message)s')
_stderr_handler = logging.StreamHandler(sys.stderr)
_stderr_handler.setFormatter(_formatter)
logger.addHandler(_stderr_handler)


def configure_logging(debug: bool, file_path: Optional[str] = None) -> None:
    """
    Configure logging level and optional file output.

    Args:
        debug:     When True, enable DEBUG level and suppress
                   Werkzeug's request log to avoid noise.
        file_path: When provided, additional log output is written to
                   this file.
    """
    if debug:
        logger.setLevel(logging.DEBUG)
        # Reduce noise from Werkzeug's request log.
        logging.getLogger('werkzeug').setLevel(logging.ERROR)
    else:
        logger.setLevel(logging.INFO)

    if file_path:
        file_handler = logging.FileHandler(file_path, encoding='utf-8')
        file_handler.setFormatter(_formatter)
        logger.addHandler(file_handler)


# ======================================================================
# Flask application
# ======================================================================

app = Flask(__name__)
# Disable Flask's default request logger; we handle logging ourselves.
app.logger.disabled = True
logging.getLogger('werkzeug').setLevel(logging.ERROR)


@app.after_request
def _after_request(response: Response) -> Response:
    """
    Add permissive CORS headers to every response.

    Wrapped in a try/except so that an unexpected response object
    (for example one produced by a Flask extension) can never prevent
    the bridge from returning a response. CORS is a courtesy, not a
    correctness requirement; failing to inject it must not turn a
    successful call into a 500.
    """
    try:
        response.headers['Access-Control-Allow-Origin'] = '*'
        response.headers['Access-Control-Allow-Headers'] = 'Content-Type'
        response.headers['Access-Control-Allow-Methods'] = 'POST, GET, OPTIONS'
    except Exception:
        # Never let CORS injection break the response path.
        logger.exception("Failed to attach CORS headers to response")
    return response


# ======================================================================
# Cleanup
# ======================================================================

# Idempotence guard. `cleanup()` is registered on atexit AND called
# from the `finally` block of `run_bridge()`. Without this flag it
# would run twice on every normal shutdown, producing duplicate log
# lines and a second (harmless but noisy) LF_ExitMainThread/LF_Shutdown
# pair. The underlying C functions are documented as safe to call
# multiple times, but there is no reason to rely on that here.
_cleanup_done = False


def cleanup() -> None:
    """
    Stop the LingoFuse main thread and shut down the library.

    Cleanup order matters and mirrors the pattern used by
    `lingofuse/server.py` (`Server.stop(full_cleanup=True)`) and by
    `test_lingofuse.py` (P0-2 fix comment):

        1. Clear network event callbacks first. This prevents a user
           callback from firing during the shutdown transition, and
           releases the Python-side strong references held by
           `lingofuse.network_events` (see the module's "REPLACE
           SEMANTICS" section).

        2. Stop the LingoFuse main thread (`LF_ExitMainThread`).

        3. Unload the library (`LF_Shutdown`).

    The bridge does not own any `App` objects (it is a pure client),
    so there is no `LF_FreeApp` step here. Apps are owned by the
    server process on the other end of the endpoint.

    Safe to call multiple times; only the first call performs work.
    """
    global _cleanup_done
    if _cleanup_done:
        return
    _cleanup_done = True

    try:
        from lingofuse.network_events import clear_network_event
        clear_network_event()
    except Exception:
        # Cleanup must never raise; log and continue.
        logger.exception("clear_network_event failed during cleanup")

    try:
        LF_ExitMainThread()
    except Exception:
        logger.exception("LF_ExitMainThread failed during cleanup")

    try:
        LF_Shutdown()
    except Exception:
        logger.exception("LF_Shutdown failed during cleanup")

    logger.info("LingoFuse resources released")


atexit.register(cleanup)


# ======================================================================
# Helpers
# ======================================================================

def jsonify_error(code: int, msg: str,
                  http_status: int = 200) -> Response:
    """
    Build a JSON error response.

    Error codes (negative, bridge-level):
        -1  Remote call failed. Raised for a timeout, a null handle
            from LF_Call, a LingoFuseError, or any unexpected internal
            exception while forwarding the request.
        -2  Request shape error. The URL path could not be parsed into
            (app_name, api_name), or no default app was configured and
            the path omitted the app segment. Always returned with
            HTTP 400 so that a caller relying on status codes still
            sees the shape error.
        -3  API pre-check failed. `check_api(app_name, api_name)`
            returned False after the configured number of retries.
            Returned with HTTP 200 so that a caller relying on a fixed
            status can still parse the JSON body and read the message.

    Args:
        code:        Bridge-level error code (negative).
        msg:         Human-readable error message.
        http_status: HTTP status code to return. Defaults to 200 so
                     that clients relying on a fixed status can still
                     parse the JSON body; request-shape errors use 400
                     instead.

    Returns:
        A Flask Response carrying the JSON-encoded error object. The
        JSON is produced via dumps_json, so the body is guaranteed to
        contain literal UTF-8 rather than \\uXXXX escapes.
    """
    return app.response_class(
        response=dumps_json({"code": code, "error": msg}).encode("utf-8"),
        status=http_status,
        mimetype='application/json',
    )


def _drain_status(n: int = 3) -> None:
    """
    Drain up to `n` pending status messages from the LingoFuse internal
    queue and forward them to the bridge logger. Useful for diagnosing
    failed calls in debug mode.

    The status queue is only reliably drained while the LingoFuse
    simulated main thread is running. This helper is therefore written
    defensively: any failure inside `get_status_num()` or
    `get_status()` is logged at debug level and swallowed, so that a
    diagnostic aid can never turn into a request-handling failure.
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
            logger.info(f"LingoFuse status: {msg}")


# ======================================================================
# Request handler
# ======================================================================

@app.route('/', defaults={'path': ''}, methods=['POST', 'OPTIONS'])
@app.route('/<path:path>', methods=['POST', 'OPTIONS'])
def handle_call(path: str):
    # CORS preflight.
    if request.method == 'OPTIONS':
        return '', 200

    # ------------------------------------------------------------------
    # Parse the path into (app_name, api_name).
    #
    # Note: str.split('/') always returns at least one element, so an
    # empty path yields [''] which is handled by the `not api_name`
    # check below.
    # ------------------------------------------------------------------
    parts = path.strip('/').split('/')
    if len(parts) == 1:
        api_name = parts[0]
        app_name = config.default_app
        if not app_name:
            return jsonify_error(
                -2, "No default app set (use --app)", 400
            )
    else:
        app_name = parts[0]
        api_name = '/'.join(parts[1:])

    if not api_name:
        return jsonify_error(
            -2, "Missing API name in path", 400
        )

    # ------------------------------------------------------------------
    # Pre-check: the check_api call is backed by a broadcast-updated
    # cache, which can lag behind registration by a few seconds. We
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
                    f"check_api({app_name}, {api_name}) "
                    f"attempt {attempt + 1} returned False"
                )
            time.sleep(0.2)  # allow the cache to propagate

        if not available:
            if config.debug:
                logger.debug(
                    f"check_api({app_name}, {api_name}) failed "
                    f"after 3 attempts"
                )
                _drain_status(3)
            return jsonify_error(
                -3,
                f"API '{api_name}' not available for app '{app_name}'",
                200,
            )

    # ------------------------------------------------------------------
    # Read the raw request body. It is forwarded as-is to the backend;
    # the bridge does not parse or modify it.
    # ------------------------------------------------------------------
    body = request.get_data()
    if config.debug:
        logger.debug(
            f"app={app_name}, api={api_name}, body_size={len(body)}"
        )
        if len(body) < 1024:
            try:
                logger.debug(
                    f"body content: "
                    f"{body.decode('utf-8', errors='replace')}"
                )
            except Exception:
                logger.debug(f"body (hex): {body.hex()[:200]}...")
        else:
            logger.debug(
                f"body (hex) first 64 bytes: {body.hex()[:64]}..."
            )

    # ------------------------------------------------------------------
    # Forward to the backend and return the response.
    #
    # All DataHandle I/O and c_char_p parameter construction goes
    # through lingofuse.lf_io. Both the request handle and the
    # response handle are released in finally blocks so that an
    # exception during payload I/O cannot leak a DataHandle.
    # ------------------------------------------------------------------
    try:
        hnd_in = LF_CreateData(cstr(api_name))
        if not hnd_in:
            raise LingoFuseError("Failed to create DataHandle")

        try:
            write_string_bytes(hnd_in, body)
            res_ptr = LF_Call(
                cstr(app_name),
                hnd_in,
                config.timeout_ms,
            )
        finally:
            LF_FreeData(hnd_in)

        if not res_ptr:
            raise LingoFuseError("Remote call returned a null handle")

        try:
            result_bytes = read_string_bytes(res_ptr)
        finally:
            LF_FreeData(res_ptr)

        if config.debug:
            logger.debug(f"Response size={len(result_bytes)}")
            if len(result_bytes) < 1024:
                try:
                    logger.debug(
                        f"response content: "
                        f"{result_bytes.decode('utf-8', errors='replace')}"
                    )
                except Exception:
                    logger.debug(
                        f"response (hex): "
                        f"{result_bytes.hex()[:200]}..."
                    )
            else:
                logger.debug(
                    f"response (hex) first 64 bytes: "
                    f"{result_bytes.hex()[:64]}..."
                )

        if not result_bytes and config.debug:
            _drain_status(3)

        return Response(
            result_bytes,
            status=200,
            content_type='application/octet-stream',
        )

    except TimeoutError:
        return jsonify_error(-1, "Call timeout", 200)
    except LingoFuseError as e:
        return jsonify_error(-1, str(e), 200)
    except Exception as e:
        return jsonify_error(-1, f"Internal error: {e}", 200)


# ======================================================================
# Network setup
# ======================================================================

def setup_network(ep: str) -> bool:
    """Establish a client connection to the LingoFuse backend endpoint."""
    try:
        # Deployment mode: do not block if the backend is not yet ready.
        # Requests will time out gracefully until it comes online.
        set_option("Wait_Connection_ReadyOk", "False")
        LF_ResetPrepare()
        LF_PrepareClient(cstr(ep), None)
        ret = LF_PrepareDone()
        if ret != 1:
            raise ConnectionError(f"LF_PrepareDone returned {ret}")
        logger.info(f"Connected to LingoFuse service: {ep}")
        return True
    except Exception as e:
        logger.error(f"Connection failed: {e}")
        return False


# ======================================================================
# Entry point
# ======================================================================

def run_bridge(
    host: str = DEFAULT_HOST,
    port: int = DEFAULT_PORT,
    endpoint_addr: str = DEFAULT_ENDPOINT,
    timeout: int = DEFAULT_TIMEOUT,
    default_app: Optional[str] = None,
    threaded_enabled: bool = DEFAULT_THREADED,
    debug: bool = DEFAULT_DEBUG,
    no_precheck_param: bool = False,
    log_file_path: Optional[str] = None,
) -> None:
    """
    Start the LingoFuse HTTP Bridge.

    Args:
        host:              Listening address.
        port:              Listening port.
        endpoint_addr:     LingoFuse service endpoint.
        timeout:           Default timeout in milliseconds for all calls.
        default_app:       Default target application name (used when the
                           path contains only an API name).
        threaded_enabled:  Enable multi-threaded request handling.
        debug:             Enable debug logging.
        no_precheck_param: Disable API pre-check (check_api).
        log_file_path:     Path to log file (None for stderr).
    """
    # Populate the module-level configuration instance.
    config.host = host
    config.port = port
    config.endpoint = endpoint_addr
    config.timeout_ms = timeout
    config.default_app = default_app
    config.threaded = threaded_enabled
    config.debug = debug
    config.no_precheck = no_precheck_param
    config.log_file = log_file_path

    configure_logging(config.debug, config.log_file)

    logger.info("=== LingoFuse HTTP Bridge (Raw Passthrough) ===")
    logger.info(f"Endpoint: {config.endpoint}")
    logger.info(
        f"Default app: "
        f"{config.default_app or '(must be specified in path)'}"
    )
    logger.info(f"Timeout: {config.timeout_ms}ms")
    logger.info(f"Threaded: {config.threaded}")
    logger.info(f"Debug: {config.debug}")
    logger.info(
        f"API pre-check: "
        f"{'Disabled' if config.no_precheck else 'Enabled (with retry)'}"
    )
    logger.info(
        "Path format: /<app>/<api>  or  /<api> (uses default app)"
    )

    if not setup_network(config.endpoint):
        sys.exit(1)

    logger.info(f"Starting HTTP service: http://{config.host}:{config.port}")
    logger.info("Press Ctrl+C to exit...")

    try:
        app.run(
            host=config.host,
            port=config.port,
            threaded=config.threaded,
            use_reloader=False,
        )
    except KeyboardInterrupt:
        logger.info("Interrupted, shutting down...")
    finally:
        cleanup()


def main() -> None:
    parser = argparse.ArgumentParser(
        description="LingoFuse HTTP Bridge (Raw Passthrough)"
    )
    parser.add_argument(
        '--host',
        default=os.environ.get('LINGOFUSE_HOST', DEFAULT_HOST),
        help=f"Listening address (default {DEFAULT_HOST})",
    )
    parser.add_argument(
        '--port',
        type=int,
        default=int(os.environ.get('LINGOFUSE_PORT', DEFAULT_PORT)),
        help=f"Listening port (default {DEFAULT_PORT})",
    )
    parser.add_argument(
        '--endpoint',
        default=os.environ.get('LINGOFUSE_ENDPOINT', DEFAULT_ENDPOINT),
        help=f"LingoFuse service endpoint (default {DEFAULT_ENDPOINT})",
    )
    parser.add_argument(
        '--timeout',
        type=int,
        default=int(os.environ.get('LINGOFUSE_TIMEOUT', DEFAULT_TIMEOUT)),
        help=f"Global timeout in milliseconds (default {DEFAULT_TIMEOUT})",
    )
    parser.add_argument(
        '--app',
        default=os.environ.get('LINGOFUSE_APP', None),
        help=(
            "Default target application name (used when the path has "
            "only an API name)"
        ),
    )
    parser.add_argument(
        '--threaded',
        dest='threaded',
        action='store_true',
        help="Enable multi-threaded request handling (default)",
    )
    parser.add_argument(
        '--no-threaded',
        dest='threaded',
        action='store_false',
        help="Disable multi-threaded request handling",
    )
    parser.add_argument(
        '--debug',
        action='store_true',
        help="Enable debug logging of request/response details",
    )
    parser.add_argument(
        '--log-file',
        default=None,
        help="Path to log file (default: stderr)",
    )
    parser.add_argument(
        '--no-precheck',
        action='store_true',
        help=(
            "Disable API pre-check (check_api) to avoid cache "
            "false negatives"
        ),
    )
    parser.set_defaults(threaded=DEFAULT_THREADED)

    args = parser.parse_args()

    run_bridge(
        host=args.host,
        port=args.port,
        endpoint_addr=args.endpoint,
        timeout=args.timeout,
        default_app=args.app,
        threaded_enabled=args.threaded,
        debug=args.debug,
        no_precheck_param=args.no_precheck,
        log_file_path=args.log_file,
    )


if __name__ == '__main__':
    main()