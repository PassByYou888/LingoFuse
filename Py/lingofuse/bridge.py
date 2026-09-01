#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
LingoFuse HTTP Bridge – Generic Binary Passthrough Gateway

This bridge acts as a stateless middleware that forwards HTTP POST requests
directly to a LingoFuse backend. It does NOT interpret or modify the request
body; it simply passes the raw binary payload to the target API and returns
the raw response.

==================== Request Format ====================
POST /<app_name>/<api_name>
Content-Type: any (ignored by bridge, but preserved for backend)
Body: arbitrary binary data (will be sent as-is to the remote API)

If only one path segment is given (e.g., /api_name), the default app
(specified via --app) is used. If no default app is set, an error is returned.

==================== Response Format ====================
Success: HTTP 200 with the raw response body from the remote call,
         with any trailing null byte (0x00) stripped to avoid JSON parse issues.
Failure (bridge-level errors): HTTP 200 with a JSON error object:
    {"code": -1, "error": "error message"}      # call error (timeout, etc.)
    {"code": -2, "error": "..."}                # request format error
    {"code": -3, "error": "API not available"}  # check_api pre-check failed

==================== Usage Examples ====================
# Start the bridge
python bridge.py --endpoint ipc:compute_grid --app pas --debug --port 8081

# Call with explicit app (path: /<app>/<api>)
curl -X POST http://127.0.0.1:8081/pas/exp -d '{"args":["1+2*3"]}'

# Call using default app (path: /<api>)
curl -X POST http://127.0.0.1:8081/exp -d '{"args":["1+2*3"]}'

==================== Command-Line Arguments ====================
--host        Listening address (default 0.0.0.0)
--port        Listening port (default 8081)
--endpoint    LingoFuse service endpoint (default ipc:lingofuse_bridge)
--timeout     Global call timeout in milliseconds (default 5000)
--app         Default target application name (used when path has only API name)
--threaded    Enable multi-threaded request handling (default)
--no-threaded Disable multi-threaded request handling
--debug       Enable debug logging of request/response details

==================== Debug Switch ====================
Use --debug to print detailed logs:
    - Request: app, api, body size and content (truncated for large data)
    - Response: size and content (truncated)
    - check_api failures and internal status messages

==================== Dependencies ====================
- lingofuse package (must be in PYTHONPATH)
- Flask
"""
import sys
import os
import json
import logging
import argparse
import atexit
import ctypes
from flask import Flask, request, Response

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from lingofuse import set_option, check_api, get_status, get_status_num
from lingofuse.errors import ConnectionError, TimeoutError, LingoFuseError
from lingofuse._lf_native import (
    LF_ResetPrepare, LF_PrepareClient, LF_PrepareDone,
    LF_Call, LF_GetBuffer, LF_GetSize, LF_FreeData,
    LF_WriteBuffer, LF_CreateData, LF_SetPos, LF_ReadBuffer,
    LF_ExitMainThread, LF_Shutdown
)

DEFAULT_HOST = '0.0.0.0'
DEFAULT_PORT = 8081
DEFAULT_ENDPOINT = 'ipc:lingofuse_bridge'
DEFAULT_TIMEOUT = 5000
DEFAULT_THREADED = True
DEFAULT_DEBUG = False

target_app = None
timeout_ms = DEFAULT_TIMEOUT
endpoint = DEFAULT_ENDPOINT
threaded = DEFAULT_THREADED
debug_mode = DEFAULT_DEBUG

app = Flask(__name__)
app.logger.disabled = True
werkzeug_log = logging.getLogger('werkzeug')
werkzeug_log.setLevel(logging.ERROR)

@app.after_request
def after_request(response):
    response.headers['Access-Control-Allow-Origin'] = '*'
    response.headers['Access-Control-Allow-Headers'] = 'Content-Type'
    response.headers['Access-Control-Allow-Methods'] = 'POST, GET, OPTIONS'
    return response

def cleanup():
    LF_ExitMainThread()
    LF_Shutdown()
    print("[Bridge] LingoFuse resources released")

atexit.register(cleanup)

@app.route('/', defaults={'path': ''}, methods=['POST', 'OPTIONS'])
@app.route('/<path:path>', methods=['POST', 'OPTIONS'])
def handle_call(path):
    if request.method == 'OPTIONS':
        return '', 200

    parts = path.strip('/').split('/')
    if len(parts) == 0:
        return jsonify_error(-2, "Empty path, expected /<app>/<api> or /<api>"), 400

    if len(parts) == 1:
        api_name = parts[0]
        app_name = target_app
        if not app_name:
            return jsonify_error(-2, "No default app set (use --app)"), 400
    else:
        app_name = parts[0]
        api_name = '/'.join(parts[1:])

    if not api_name:
        return jsonify_error(-2, "Missing API name in path"), 400

    # Pre-check API availability
    if not check_api(app_name, api_name):
        if debug_mode:
            print(f"[DEBUG] check_api({app_name}, {api_name}) returned False")
        if get_status_num() > 0:
            for _ in range(min(3, get_status_num())):
                msg = get_status()
                if msg:
                    print(f"[STATUS] {msg}")
        return jsonify_error(-3, f"API '{api_name}' not available for app '{app_name}'"), 200

    body = request.get_data()
    if debug_mode:
        print(f"[DEBUG] app={app_name}, api={api_name}, body_size={len(body)}")
        if len(body) < 1024:
            try:
                print(f"[DEBUG] body content: {body.decode('utf-8', errors='replace')}")
            except:
                print(f"[DEBUG] body (hex): {body.hex()[:200]}...")
        else:
            print(f"[DEBUG] body (hex) first 64 bytes: {body.hex()[:64]}...")

    try:
        hnd_in = LF_CreateData(api_name.encode('utf-8'))
        if not hnd_in:
            raise LingoFuseError("Failed to create DataHandle")

        # Write request body + null terminator to be compatible with Pascal LF_ReadString
        if body:
            data_to_send = body + b'\x00'
            written = LF_WriteBuffer(hnd_in, data_to_send, len(data_to_send))
            if written != len(data_to_send):
                LF_FreeData(hnd_in)
                raise LingoFuseError(f"WriteBuffer wrote only {written} of {len(data_to_send)} bytes")
        else:
            LF_WriteBuffer(hnd_in, b'\x00', 1)

        res_ptr = LF_Call(app_name.encode('utf-8'), hnd_in, timeout_ms)
        LF_FreeData(hnd_in)

        if not res_ptr:
            raise LingoFuseError("Remote call returned null handle")

        size = LF_GetSize(res_ptr)
        if debug_mode:
            print(f"[DEBUG] Response size: {size}")

        if size == 0:
            LF_FreeData(res_ptr)
            if get_status_num() > 0:
                for _ in range(min(3, get_status_num())):
                    msg = get_status()
                    if msg:
                        print(f"[STATUS] {msg}")
            return Response(b'', status=200, content_type='application/octet-stream')

        # Read response using LF_ReadBuffer (reliable for binary data)
        buf = (ctypes.c_byte * size)()
        LF_SetPos(res_ptr, 0)
        read = LF_ReadBuffer(res_ptr, buf, size)
        LF_FreeData(res_ptr)

        if read != size:
            raise RuntimeError(f"Read mismatch: expected {size}, got {read}")

        result_bytes = bytes(buf)

        # Remove trailing null byte if present (to avoid JSON parse errors in HTTP clients)
        if result_bytes and result_bytes[-1] == 0:
            result_bytes = result_bytes[:-1]

        if debug_mode:
            print(f"[DEBUG] Response size={len(result_bytes)}")
            if len(result_bytes) < 1024:
                try:
                    print(f"[DEBUG] response content: {result_bytes.decode('utf-8', errors='replace')}")
                except:
                    print(f"[DEBUG] response (hex): {result_bytes.hex()[:200]}...")
            else:
                print(f"[DEBUG] response (hex) first 64 bytes: {result_bytes.hex()[:64]}...")

        return Response(result_bytes, status=200, content_type='application/octet-stream')

    except TimeoutError:
        return jsonify_error(-1, "Call timeout"), 200
    except LingoFuseError as e:
        return jsonify_error(-1, str(e)), 200
    except Exception as e:
        return jsonify_error(-1, f"Internal error: {e}"), 200

def jsonify_error(code, msg):
    return app.response_class(
        response=json.dumps({"code": code, "error": msg}),
        status=200,
        mimetype='application/json'
    )

def setup_network(ep):
    try:
        set_option("Wait_Connection_ReadyOk", "False")
        LF_ResetPrepare()
        LF_PrepareClient(ep.encode('utf-8'), None)
        ret = LF_PrepareDone()
        if ret != 1:
            raise ConnectionError(f"LF_PrepareDone returned {ret}")
        print(f"[Bridge] Connected to LingoFuse service: {ep}")
        return True
    except Exception as e:
        print(f"[ERROR] Connection failed: {e}")
        return False

def run_bridge(host=DEFAULT_HOST, port=DEFAULT_PORT,
               endpoint_addr=DEFAULT_ENDPOINT, timeout=DEFAULT_TIMEOUT,
               default_app=None, threaded_enabled=DEFAULT_THREADED,
               debug=DEFAULT_DEBUG):
    """
    Start the LingoFuse HTTP Bridge.

    Args:
        host: Listening address
        port: Listening port
        endpoint_addr: LingoFuse service endpoint
        timeout: Default timeout in milliseconds for all calls
        default_app: Default target application name (used when path has only API)
        threaded_enabled: Enable multi-threaded request handling
        debug: Enable debug logging
    """
    global target_app, timeout_ms, endpoint, threaded, debug_mode

    target_app = default_app
    timeout_ms = timeout
    endpoint = endpoint_addr
    threaded = threaded_enabled
    debug_mode = debug

    print("=== LingoFuse HTTP Bridge (Raw Passthrough) ===")
    print(f"Endpoint: {endpoint}")
    print(f"Default app: {target_app or '(must be specified in path)'}")
    print(f"Timeout: {timeout_ms}ms")
    print(f"Threaded: {threaded}")
    print(f"Debug: {debug_mode}")
    print("Path format: /<app>/<api>  or  /<api> (uses default app)")

    if not setup_network(endpoint):
        sys.exit(1)

    print(f"Starting HTTP service: http://{host}:{port}")
    print("Press Ctrl+C to exit...")

    try:
        app.run(host=host, port=port, threaded=threaded, use_reloader=False)
    except KeyboardInterrupt:
        print("\n[Bridge] Interrupted, shutting down...")
    finally:
        cleanup()

def main():
    parser = argparse.ArgumentParser(description="LingoFuse HTTP Bridge (Raw Passthrough)")
    parser.add_argument('--host', default=os.environ.get('LINGOFUSE_HOST', DEFAULT_HOST),
                        help="Listening address (default {})".format(DEFAULT_HOST))
    parser.add_argument('--port', type=int, default=int(os.environ.get('LINGOFUSE_PORT', DEFAULT_PORT)),
                        help="Listening port (default {})".format(DEFAULT_PORT))
    parser.add_argument('--endpoint', default=os.environ.get('LINGOFUSE_ENDPOINT', DEFAULT_ENDPOINT),
                        help="LingoFuse service endpoint (default {})".format(DEFAULT_ENDPOINT))
    parser.add_argument('--timeout', type=int, default=int(os.environ.get('LINGOFUSE_TIMEOUT', DEFAULT_TIMEOUT)),
                        help="Global timeout in milliseconds (default {})".format(DEFAULT_TIMEOUT))
    parser.add_argument('--app', default=os.environ.get('LINGOFUSE_APP', None),
                        help="Default target application name (used when path has only API name)")
    parser.add_argument('--threaded', dest='threaded', action='store_true',
                        help="Enable multi-threaded request handling (default)")
    parser.add_argument('--no-threaded', dest='threaded', action='store_false',
                        help="Disable multi-threaded request handling")
    parser.add_argument('--debug', action='store_true',
                        help="Enable debug logging of request/response details")
    parser.set_defaults(threaded=DEFAULT_THREADED)

    args = parser.parse_args()

    run_bridge(host=args.host, port=args.port,
               endpoint_addr=args.endpoint, timeout=args.timeout,
               default_app=args.app, threaded_enabled=args.threaded,
               debug=args.debug)

if __name__ == '__main__':
    main()