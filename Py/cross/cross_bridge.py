#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Cross Bridge – LingoFuse Service Adapter with external HTTP gateway

This script acts as a LingoFuse service that exposes the 'add' and 'inv_seri'
APIs. It connects to the actual demo node (via ipc:cross) and forwards calls
to it. After the service is ready, it launches the generic HTTP bridge
(bridge.py) as a subprocess, so that HTTP clients can access the APIs.

Usage:
    python cross_bridge.py [--endpoint SERVICE_ENDPOINT] [--node-endpoint NODE_ENDPOINT]
                           [--app-name APP_NAME] [--timeout TIMEOUT]
                           [--http-port PORT] [--bridge-path PATH]

Environment variables:
    CROSS_BRIDGE_ENDPOINT   - Service endpoint (default ipc:cross_bridge_service)
    CROSS_BRIDGE_NODE       - Node endpoint (default ipc:cross)
    CROSS_BRIDGE_APP        - Application name (default cross_bridge)
    CROSS_BRIDGE_TIMEOUT    - Call timeout in ms (default 5000)
    CROSS_BRIDGE_HTTP_PORT  - HTTP port for bridge (default 8081)
    CROSS_BRIDGE_BRIDGE_PATH - Path to bridge.py (default ../lingofuse/bridge.py)

Example:
    python cross_bridge.py --endpoint ipc:cross_bridge_service --node-endpoint ipc:cross
"""
from __future__ import annotations   # Allows forward references for type hints

import sys
import os
import argparse
import atexit
import time
import subprocess
import signal
import threading

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from lingofuse import App, _lf_native
from lingofuse.core import DataHandle
from lingofuse.errors import RegistrationError

# ---------- Default configuration ----------
DEFAULT_ENDPOINT = 'ipc:cross_bridge_service'
DEFAULT_NODE_ENDPOINT = 'ipc:cross'
DEFAULT_APP_NAME = 'cross_bridge'
DEFAULT_TIMEOUT = 5000  # ms
DEFAULT_HTTP_PORT = 8081
DEFAULT_BRIDGE_PATH = os.path.join(os.path.dirname(__file__), '..', 'lingofuse', 'bridge.py')

# ---------- Global variables ----------
service_app = None
timeout_ms = DEFAULT_TIMEOUT
node_app_name = 'demo'
node_endpoint = DEFAULT_NODE_ENDPOINT
http_port = DEFAULT_HTTP_PORT
bridge_script_path = DEFAULT_BRIDGE_PATH
bridge_process = None

# ---------- Cleanup ----------
def cleanup():
    global bridge_process
    if bridge_process:
        bridge_process.terminate()
        try:
            bridge_process.wait(timeout=2)
        except subprocess.TimeoutExpired:
            bridge_process.kill()
        bridge_process = None
    if service_app:
        service_app.free()
    _lf_native.LF_ExitMainThread()
    _lf_native.LF_Shutdown()
    print("[CrossBridge] Resources released")

atexit.register(cleanup)

# ---------- API Callbacks ----------
# Note: We avoid type hints that may cause runtime NameError. If you want type hints,
# enable `from __future__ import annotations` (already done above).

def add_callback(trigger, inp, out):
    """Add callback: accepts JSON object {'a':..., 'b':...} or list [a,b]."""
    global timeout_ms
    try:
        data = inp.read_json()
        if data is None:
            raise ValueError("Missing or invalid JSON input")
        # Support both dict and list inputs
        if isinstance(data, dict):
            a = data.get('a')
            b = data.get('b')
            if a is None or b is None:
                raise ValueError("Missing 'a' or 'b' in dict input")
        elif isinstance(data, list):
            if len(data) < 2:
                raise ValueError("List input requires at least 2 elements")
            a = data[0]
            b = data[1]
        else:
            raise ValueError("Unsupported input type")
        # Call the node using raw binary
        param = DataHandle("add")
        param.write_int32(a)
        param.write_int32(b)
        res_ptr = _lf_native.LF_Call(node_app_name.encode('utf-8'), param.raw, timeout_ms)
        param.free()
        if not res_ptr:
            raise RuntimeError("Node call returned null handle")
        size = _lf_native.LF_GetSize(res_ptr)
        if size == 0:
            _lf_native.LF_FreeData(res_ptr)
            raise RuntimeError("Node call returned empty result")
        result_hnd = DataHandle._from_raw(res_ptr, owned=True)
        result = result_hnd.read_int32()
        result_hnd.free()
        # Write JSON output (standard format: {"code":0, "result": value})
        out.write_json({"code": 0, "result": result})
        print(f"[CrossBridge] add({a}, {b}) -> {result}")
    except Exception as e:
        print(f"[ERROR] add_callback: {e}")
        out.write_json({"code": -1, "error": str(e)})

def inv_seri_callback(trigger, inp, out):
    """inv_seri callback: accepts dict or list, returns formatted string."""
    global timeout_ms
    try:
        # Default values
        default_b, default_w, default_c, default_u64, default_s, default_f = 200, 0x10, 0x2F, 0x3F, "hello world", 3.14
        data = inp.read_json()
        if data is None or data == []:
            # No input or empty list → use defaults
            b, w, c, u64, s, f = default_b, default_w, default_c, default_u64, default_s, default_f
        elif isinstance(data, dict):
            b = data.get('b', default_b)
            w = data.get('w', default_w)
            c = data.get('c', default_c)
            u64 = data.get('u64', default_u64)
            s = data.get('s', default_s)
            f = data.get('f', default_f)
        elif isinstance(data, list):
            # Fill missing elements with defaults
            b = data[0] if len(data) > 0 else default_b
            w = data[1] if len(data) > 1 else default_w
            c = data[2] if len(data) > 2 else default_c
            u64 = data[3] if len(data) > 3 else default_u64
            s = data[4] if len(data) > 4 else default_s
            f = data[5] if len(data) > 5 else default_f
        else:
            raise ValueError("Unsupported input type")
        # Build binary payload to send to the node
        tmp = DataHandle("inv_seri")
        tmp.write_uint8(b)
        tmp.write_uint16(w)
        tmp.write_uint32(c)
        tmp.write_uint64(u64)
        tmp.write_string(s)          # auto \0
        tmp.write_single(f)
        res_ptr = _lf_native.LF_Call(node_app_name.encode('utf-8'), tmp.raw, timeout_ms)
        tmp.free()
        if not res_ptr:
            raise RuntimeError("Node call returned null handle")
        size = _lf_native.LF_GetSize(res_ptr)
        if size == 0:
            _lf_native.LF_FreeData(res_ptr)
            raise RuntimeError("Node call returned empty result")
        result = DataHandle._from_raw(res_ptr, owned=True)
        f_ret = result.read_single()
        s_ret = result.read_string()          # auto strips \0
        u64_ret = result.read_uint64()
        c_ret = result.read_uint32()
        w_ret = result.read_uint16()
        b_ret = result.read_uint8()
        result.free()
        # Build a formatted string (like the original Pascal demo)
        result_str = (f"Received data sequence [{b_ret}, {w_ret}, {c_ret}, {u64_ret}, \"{s_ret}\", {f_ret:.2f}] = "
                      f"Sent data sequence [{f_ret:.2f}, \"{s_ret}\", {u64_ret}, {c_ret}, {w_ret}, {b_ret}]")
        # Write JSON output (standard format)
        out.write_json({"code": 0, "result": result_str})
        print(f"[CrossBridge] inv_seri: sent [{b},{w},{c},{u64},{s},{f}] -> received [{b_ret},{w_ret},{c_ret},{u64_ret},{s_ret},{f_ret}]")
    except Exception as e:
        print(f"[ERROR] inv_seri_callback: {e}")
        out.write_json({"code": -1, "error": str(e)})

# ---------- Setup network ----------
def setup_service(endpoint, node_ep, app_name, timeout):
    global service_app, timeout_ms, node_endpoint
    timeout_ms = timeout
    node_endpoint = node_ep

    # Create the application and register APIs
    service_app = App(app_name, "Cross Bridge Service")
    try:
        service_app.register_call("add", add_callback, "add(a,b) -> sum")
        service_app.register_call("inv_seri", inv_seri_callback, "inv_seri()")
        print("[CrossBridge] Registered APIs 'add' and 'inv_seri'")
    except RegistrationError as e:
        print(f"[ERROR] Failed to register APIs: {e}")
        return False

    # Set Wait_Connection_ReadyOk to True so LF_PrepareDone blocks until all
    # clients are connected and registered.
    _lf_native.LF_SetOption(b"Wait_Connection_ReadyOk", b"True")
    print("[CrossBridge] Wait_Connection_ReadyOk set to True")

    # Reset any previous preparation state
    _lf_native.LF_ResetPrepare()

    # 1. Create the service endpoint (so other clients can find us)
    serv_ret = _lf_native.LF_PrepareService(endpoint.encode('utf-8'), endpoint.encode('utf-8'))
    if serv_ret == -1:
        print(f"[ERROR] LF_PrepareService failed for endpoint {endpoint}. Address may be in use.")
        return False
    print(f"[CrossBridge] Service prepared on {endpoint}")

    # 2. Connect to the demo node as a consumer (no app attached)
    client_ret = _lf_native.LF_PrepareClient(node_ep.encode('utf-8'), None)
    if client_ret == -1:
        print(f"[WARNING] LF_PrepareClient to node {node_ep} returned -1 (maybe already connected)")
    else:
        print(f"[CrossBridge] Consumer client prepared for node {node_ep}")

    # 3. Connect to our own service, attaching our application
    self_client_ret = _lf_native.LF_PrepareClient(endpoint.encode('utf-8'), service_app.raw)
    if self_client_ret == -1:
        print(f"[ERROR] LF_PrepareClient to our own service {endpoint} failed. Address may be duplicate.")
        return False
    print(f"[CrossBridge] Self-client prepared for endpoint {endpoint}")

    # Start the framework (this will block until all clients are ready)
    ret = _lf_native.LF_PrepareDone()
    if ret != 1:
        print("[ERROR] LF_PrepareDone returned 0. Check console output for errors.")
        num = _lf_native.LF_GetStatusCount()
        if num > 0:
            for _ in range(min(num, 5)):
                msg = _lf_native.LF_GetStatus().decode('utf-8', errors='replace')
                print(f"[STATUS] {msg}")
        return False
    else:
        print("[CrossBridge] Network ready.")

    # Verify that our application is now visible to the network
    time.sleep(0.5)
    if _lf_native.LF_CheckApp(app_name.encode('utf-8')) == 0:
        print(f"[ERROR] Application '{app_name}' is not visible after PrepareDone. Check registration.")
        return False
    else:
        print(f"[CrossBridge] Application '{app_name}' is online and visible.")

    print(f"[CrossBridge] Service started on {endpoint}")
    return True

# ---------- Launch bridge.py as subprocess ----------
def launch_bridge(endpoint, port, bridge_path):
    global bridge_process
    if not os.path.exists(bridge_path):
        print(f"[ERROR] bridge.py not found at {bridge_path}")
        return False
    cmd = [
        sys.executable,
        bridge_path,
        '--endpoint', endpoint,
        '--port', str(port),
        '--no-precheck',
        '--debug'
    ]
    print(f"[CrossBridge] Launching HTTP gateway: {' '.join(cmd)}")
    try:
        # Use CREATE_NEW_PROCESS_GROUP on Windows to allow Ctrl+C handling
        if sys.platform == 'win32':
            creationflags = subprocess.CREATE_NEW_PROCESS_GROUP
        else:
            creationflags = 0
        bridge_process = subprocess.Popen(
            cmd,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            universal_newlines=True,
            creationflags=creationflags
        )
        # Print output from bridge in a separate thread to avoid blocking
        def print_bridge_output():
            for line in iter(bridge_process.stdout.readline, ''):
                sys.stdout.write(f"[bridge] {line}")
        threading.Thread(target=print_bridge_output, daemon=True).start()
        print(f"[CrossBridge] HTTP gateway started on http://0.0.0.0:{port}")
        return True
    except Exception as e:
        print(f"[ERROR] Failed to launch HTTP gateway: {e}")
        return False

# ---------- Main ----------
def main():
    parser = argparse.ArgumentParser(description="Cross Bridge LingoFuse Service with HTTP Gateway")
    parser.add_argument('--endpoint', default=os.environ.get('CROSS_BRIDGE_ENDPOINT', DEFAULT_ENDPOINT),
                        help=f"Service endpoint (default {DEFAULT_ENDPOINT})")
    parser.add_argument('--node-endpoint', default=os.environ.get('CROSS_BRIDGE_NODE', DEFAULT_NODE_ENDPOINT),
                        help=f"Demo node endpoint (default {DEFAULT_NODE_ENDPOINT})")
    parser.add_argument('--app-name', default=os.environ.get('CROSS_BRIDGE_APP', DEFAULT_APP_NAME),
                        help=f"Application name (default {DEFAULT_APP_NAME})")
    parser.add_argument('--timeout', type=int, default=int(os.environ.get('CROSS_BRIDGE_TIMEOUT', DEFAULT_TIMEOUT)),
                        help=f"Call timeout in ms (default {DEFAULT_TIMEOUT})")
    parser.add_argument('--http-port', type=int, default=int(os.environ.get('CROSS_BRIDGE_HTTP_PORT', DEFAULT_HTTP_PORT)),
                        help=f"HTTP port for bridge (default {DEFAULT_HTTP_PORT})")
    parser.add_argument('--bridge-path', default=os.environ.get('CROSS_BRIDGE_BRIDGE_PATH', DEFAULT_BRIDGE_PATH),
                        help=f"Path to bridge.py (default {DEFAULT_BRIDGE_PATH})")
    args = parser.parse_args()

    global http_port, bridge_script_path
    http_port = args.http_port
    bridge_script_path = args.bridge_path

    print("=== Cross Bridge Service ===")
    print(f"Service endpoint: {args.endpoint}")
    print(f"Node endpoint: {args.node_endpoint}")
    print(f"App name: {args.app_name}")
    print(f"Timeout: {args.timeout}ms")
    print(f"HTTP bridge: {bridge_script_path} on port {http_port}")

    if not setup_service(args.endpoint, args.node_endpoint, args.app_name, args.timeout):
        sys.exit(1)

    # Launch HTTP gateway as a separate process
    if not launch_bridge(args.endpoint, http_port, bridge_script_path):
        print("[CrossBridge] HTTP gateway failed to start, but LingoFuse service is running.")
        print("[CrossBridge] You can manually start bridge.py with:")
        print(f"  {sys.executable} {bridge_script_path} --endpoint {args.endpoint} --port {http_port} --no-precheck --debug")

    print("[CrossBridge] Service is running. Press Ctrl+C to stop all processes.")
    try:
        while True:
            time.sleep(1)
    except KeyboardInterrupt:
        print("\n[CrossBridge] Interrupted, shutting down...")
    finally:
        cleanup()

if __name__ == '__main__':
    main()