#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Cross Bridge – LingoFuse Service Adapter

This script acts as a LingoFuse service that exposes the 'add' and 'inv_seri'
APIs. It connects to the actual demo node (via ipc:cross) and forwards calls
to it. The service can be consumed by any LingoFuse client (e.g., the generic
bridge.py) to provide HTTP access.

It uses JSON serialization for its own API, but communicates with the demo
node using raw binary (the original node API).

Usage:
    python cross_bridge.py [--endpoint SERVICE_ENDPOINT] [--node-endpoint NODE_ENDPOINT]
                           [--app-name APP_NAME] [--timeout TIMEOUT]

Environment variables:
    CROSS_BRIDGE_ENDPOINT   - Service endpoint (default ipc:cross_bridge_service)
    CROSS_BRIDGE_NODE       - Node endpoint (default ipc:cross)
    CROSS_BRIDGE_APP        - Application name (default cross_bridge)
    CROSS_BRIDGE_TIMEOUT    - Call timeout in ms (default 5000)

Example:
    python cross_bridge.py --endpoint ipc:cross_bridge_service --node-endpoint ipc:cross
"""
import sys
import os
import argparse
import atexit
import time
import json
import base64
import struct
import ctypes

# Ensure lingofuse can be imported
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from lingofuse import App, _lf_native
from lingofuse.core import DataHandle
from lingofuse.errors import RegistrationError, LingoFuseError

# ---------- Default configuration ----------
DEFAULT_ENDPOINT = 'ipc:cross_bridge_service'
DEFAULT_NODE_ENDPOINT = 'ipc:cross'
DEFAULT_APP_NAME = 'cross_bridge'
DEFAULT_TIMEOUT = 5000  # ms

# ---------- Global variables ----------
service_app = None
timeout_ms = DEFAULT_TIMEOUT
node_app_name = 'demo'
node_endpoint = DEFAULT_NODE_ENDPOINT

# ---------- JSON helpers (same as in server.py) ----------
def _convert_to_serializable(obj):
    if isinstance(obj, bytes):
        return {"__bytes__": base64.b64encode(obj).decode("ascii")}
    elif isinstance(obj, list):
        return [_convert_to_serializable(item) for item in obj]
    elif isinstance(obj, dict):
        return {k: _convert_to_serializable(v) for k, v in obj.items()}
    else:
        return obj

def _convert_from_serializable(obj):
    if isinstance(obj, dict):
        if len(obj) == 1 and "__bytes__" in obj:
            try:
                return base64.b64decode(obj["__bytes__"])
            except Exception:
                return obj
        else:
            return {k: _convert_from_serializable(v) for k, v in obj.items()}
    elif isinstance(obj, list):
        return [_convert_from_serializable(item) for item in obj]
    else:
        return obj

def _read_json(hnd):
    size = _lf_native.LF_GetSize(hnd.raw)
    if size == 0:
        return None
    buf = (ctypes.c_byte * size)()
    _lf_native.LF_SetPos(hnd.raw, 0)
    _lf_native.LF_ReadBuffer(hnd.raw, buf, size)
    raw = bytes(buf)
    null = raw.find(b'\x00')
    if null != -1:
        raw = raw[:null]
    try:
        data = json.loads(raw.decode("utf-8"))
        return _convert_from_serializable(data)
    except Exception:
        return None

def _write_json(hnd, obj):
    serializable = _convert_to_serializable(obj)
    data = json.dumps(serializable, ensure_ascii=False).encode("utf-8") + b'\x00'
    _lf_native.LF_WriteBuffer(hnd.raw, data, len(data))

# ---------- Cleanup ----------
def cleanup():
    global service_app
    if service_app:
        service_app.free()
    _lf_native.LF_ExitMainThread()
    _lf_native.LF_Shutdown()
    print("[CrossBridge] Resources released")

atexit.register(cleanup)

# ---------- API Callbacks ----------
def add_callback(trigger, inp: DataHandle, out: DataHandle):
    """Add callback: accepts JSON object {'a':..., 'b':...} or list [a,b]."""
    global timeout_ms
    try:
        data = _read_json(inp)
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
        _write_json(out, {"code": 0, "result": result})
        print(f"[CrossBridge] add({a}, {b}) -> {result}")
    except Exception as e:
        print(f"[ERROR] add_callback: {e}")
        _write_json(out, {"code": -1, "error": str(e)})

def inv_seri_callback(trigger, inp: DataHandle, out: DataHandle):
    """inv_seri callback: accepts dict or list, returns formatted string."""
    global timeout_ms
    try:
        # Default values
        default_b, default_w, default_c, default_u64, default_s, default_f = 200, 0x10, 0x2F, 0x3F, "hello world", 3.14
        data = _read_json(inp)
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
        tmp.write_string_null_terminated(s)
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
        s_ret = result.read_string_null_terminated()
        u64_ret = result.read_uint64()
        c_ret = result.read_uint32()
        w_ret = result.read_uint16()
        b_ret = result.read_uint8()
        result.free()
        # Build a formatted string (like the original Pascal demo)
        result_str = (f"接收数据序 [{b_ret}, {w_ret}, {c_ret}, {u64_ret}, \"{s_ret}\", {f_ret:.2f}] = "
                      f"发送数据序 [{f_ret:.2f}, \"{s_ret}\", {u64_ret}, {c_ret}, {w_ret}, {b_ret}]")
        # Write JSON output (standard format)
        _write_json(out, {"code": 0, "result": result_str})
        print(f"[CrossBridge] inv_seri: sent [{b},{w},{c},{u64},{s},{f}] -> received [{b_ret},{w_ret},{c_ret},{u64_ret},{s_ret},{f_ret}]")
    except Exception as e:
        print(f"[ERROR] inv_seri_callback: {e}")
        _write_json(out, {"code": -1, "error": str(e)})

# ---------- Setup network ----------
def setup_service(endpoint, node_ep, app_name, timeout):
    global service_app, timeout_ms, node_endpoint
    timeout_ms = timeout
    node_endpoint = node_ep

    # 1. Create the service application and register APIs
    service_app = App(app_name, "Cross Bridge Service")
    try:
        service_app.register_call("add", add_callback, "add(a,b) -> sum")
        service_app.register_call("inv_seri", inv_seri_callback, "inv_seri()")
        print("[CrossBridge] Registered APIs 'add' and 'inv_seri'")
    except RegistrationError as e:
        print(f"[ERROR] Failed to register APIs: {e}")
        return False

    # 2. Prepare network: start service and client connections in one batch
    _lf_native.LF_ResetPrepare()
    # Expose our service on the specified endpoint
    _lf_native.LF_PrepareService(endpoint.encode('utf-8'), endpoint.encode('utf-8'))
    # Connect to the demo node (as a client) – no app exposed
    _lf_native.LF_PrepareClient(node_ep.encode('utf-8'), None)
    # Connect to our own service to allow external clients to discover us
    _lf_native.LF_PrepareClient(endpoint.encode('utf-8'), service_app.raw)

    # 3. Start the framework
    ret = _lf_native.LF_PrepareDone()
    if ret != 1:
        if _lf_native.LF_CheckMainThread() == 0:
            # Fetch last few status messages for diagnosis
            num = _lf_native.LF_GetStatusCount()
            if num > 0:
                for _ in range(min(num, 5)):
                    msg = _lf_native.LF_GetStatus().decode('utf-8', errors='replace')
                    print(f"[STATUS] {msg}")
            print("[ERROR] Main thread not running, service start failed.")
            return False
        else:
            print(f"[WARNING] LF_PrepareDone returned {ret}, but main thread is running. Continuing.")
    else:
        print("[CrossBridge] Network ready.")

    print(f"[CrossBridge] Service started on {endpoint}")
    return True

# ---------- Main ----------
def main():
    parser = argparse.ArgumentParser(description="Cross Bridge LingoFuse Service")
    parser.add_argument('--endpoint', default=os.environ.get('CROSS_BRIDGE_ENDPOINT', DEFAULT_ENDPOINT),
                        help=f"Service endpoint (default {DEFAULT_ENDPOINT})")
    parser.add_argument('--node-endpoint', default=os.environ.get('CROSS_BRIDGE_NODE', DEFAULT_NODE_ENDPOINT),
                        help=f"Demo node endpoint (default {DEFAULT_NODE_ENDPOINT})")
    parser.add_argument('--app-name', default=os.environ.get('CROSS_BRIDGE_APP', DEFAULT_APP_NAME),
                        help=f"Application name (default {DEFAULT_APP_NAME})")
    parser.add_argument('--timeout', type=int, default=int(os.environ.get('CROSS_BRIDGE_TIMEOUT', DEFAULT_TIMEOUT)),
                        help=f"Call timeout in ms (default {DEFAULT_TIMEOUT})")
    args = parser.parse_args()

    print("=== Cross Bridge Service ===")
    print(f"Service endpoint: {args.endpoint}")
    print(f"Node endpoint: {args.node_endpoint}")
    print(f"App name: {args.app_name}")
    print(f"Timeout: {args.timeout}ms")

    if not setup_service(args.endpoint, args.node_endpoint, args.app_name, args.timeout):
        sys.exit(1)

    print("[CrossBridge] Service is running. Press Ctrl+C to stop.")
    try:
        while True:
            time.sleep(1)
    except KeyboardInterrupt:
        print("\n[CrossBridge] Interrupted, shutting down...")
    finally:
        cleanup()

if __name__ == '__main__':
    main()