#!/usr/bin/env python3
# -*- coding: utf-8 -*-

"""
LingoFuse LLM Test Client – dynamic session client (corrected order).

This client first establishes a plain network connection (without binding an App),
then generates a unique client name using generate_app_name() after the connection
is fully ready. It then creates an App with that name, registers the notify callback,
binds the App to the existing client, and sends a generation request with the
client_name. All comments and logs are in English.
"""
import sys
import os
import json
import argparse
import threading
import time

sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..'))

from lingofuse import App, generate_app_name, set_option, check_main_thread
from lingofuse.core import DataHandle
from lingofuse._lf_native import (
    LF_ResetPrepare, LF_PrepareClient, LF_PrepareDone,
    LF_Call, LF_ExitMainThread, LF_Shutdown,
    LF_BindApp, LF_GetStatusCount, LF_GetStatus,
)

# ----------------------------------------------------------------------
# Defaults
# ----------------------------------------------------------------------
DEFAULT_ENDPOINT = "ipc:llm_service"
DEFAULT_SERVER_APP = "LLM_Service"
DEFAULT_NOTIFY_API = "llm_stream"
DEFAULT_TIMEOUT_MS = 10000
DEFAULT_CONTENT = "print('Hello World')"
DEFAULT_PROMPT = "Explain this code in Chinese."
DEFAULT_SYSTEM_MESSAGE = None  # optional

# ----------------------------------------------------------------------
# Argument parsing
# ----------------------------------------------------------------------
def parse_args():
    parser = argparse.ArgumentParser(description="LingoFuse LLM Test Client – dynamic session")
    parser.add_argument("--content", default=os.environ.get("LLM_CONTENT", DEFAULT_CONTENT))
    parser.add_argument("--prompt", default=os.environ.get("LLM_PROMPT", DEFAULT_PROMPT))
    parser.add_argument("--system-message", default=os.environ.get("LLM_SYSTEM_MESSAGE", DEFAULT_SYSTEM_MESSAGE))
    parser.add_argument("--endpoint", default=os.environ.get("LINGOFUSE_ENDPOINT", DEFAULT_ENDPOINT))
    parser.add_argument("--server-app", default=os.environ.get("LLM_SERVER_APP", DEFAULT_SERVER_APP))
    parser.add_argument("--notify-api", default=os.environ.get("LLM_NOTIFY_API", DEFAULT_NOTIFY_API))
    parser.add_argument("--timeout", type=int, default=int(os.environ.get("LINGOFUSE_TIMEOUT", str(DEFAULT_TIMEOUT_MS))))
    parser.add_argument("--debug", action="store_true", default=os.environ.get("LLM_DEBUG", "0").lower() in ("1", "true", "yes"))
    return parser.parse_args()

# ----------------------------------------------------------------------
# Remote call helper
# ----------------------------------------------------------------------
def remote_call(server_app: str, api_name: str, request_json: dict, timeout_ms: int):
    """Send a Call request and return the response dict, or None on error."""
    hnd = DataHandle(api_name)
    hnd.write_json(request_json)
    res_hnd = LF_Call(server_app.encode("utf-8"), hnd.raw, timeout_ms)
    hnd.free()
    if not res_hnd:
        print(f"[Client] ERROR: Call to {api_name} returned null handle", file=sys.stderr)
        return None
    resp = DataHandle._from_raw(res_hnd, owned=True)
    try:
        result = resp.read_json()
        return result
    except Exception as e:
        print(f"[Client] ERROR: Failed to parse response from {api_name}: {e}", file=sys.stderr)
        return None
    finally:
        resp.free()

# ----------------------------------------------------------------------
# Main
# ----------------------------------------------------------------------
def main():
    args = parse_args()
    if args.debug:
        print("[DEBUG] Configuration:", file=sys.stderr)
        for k, v in vars(args).items():
            print(f"  {k} = {v}", file=sys.stderr)

    # Step 1: Prepare network connection WITHOUT binding an App yet
    print(f"[Client] Connecting to service at {args.endpoint} ...")
    LF_ResetPrepare()

    # Explicitly set Wait_Connection_ReadyOk to True to block PrepareDone until the client is fully ready
    set_option("Wait_Connection_ReadyOk", "True")
    print("[Client] Option 'Wait_Connection_ReadyOk' set to True")

    ret = LF_PrepareClient(args.endpoint.encode("utf-8"), None)  # no App attached yet
    if ret == -1:
        print(f"[Client] ERROR: LF_PrepareClient failed for endpoint {args.endpoint}", file=sys.stderr)
        sys.exit(1)

    if LF_PrepareDone() != 1:
        if check_main_thread():
            print("[Client] WARNING: LF_PrepareDone returned non-1, but main thread is active. Continuing.")
        else:
            print("[Client] ERROR: LF_PrepareDone failed", file=sys.stderr)
            LF_ExitMainThread()
            LF_Shutdown()
            sys.exit(1)

    print("[Client] Network connection established successfully.")

    # Step 2: Generate unique client name NOW (after connection is up)
    client_name = generate_app_name()
    print(f"[Client] Generated unique client name: {client_name}")

    # Step 3: Create App with that name and register notify callback
    app = App(client_name, "Dynamic LLM Client")
    finish_event = threading.Event()

    def on_llm_stream(trigger, inp: DataHandle):
        """Callback for sequenced notifications."""
        size = inp.get_size()
        if size == 0:
            return
        try:
            data = inp.read_json()
            if data is None:
                return
            chunk = data.get("chunk")
            if chunk == "__FINISH__":
                print("\n[Client] Received FINISH signal")
                finish_event.set()
            elif chunk.startswith("__ERROR__"):
                print(f"\n[Client] Error from server: {chunk}")
                finish_event.set()
            else:
                print(chunk, end="", flush=True)
        except Exception as e:
            print(f"[Client] Callback exception: {e}", file=sys.stderr)
            finish_event.set()

    print(f"[Client] Registering notify callback for API '{args.notify_api}'")
    app.register_notify(args.notify_api, on_llm_stream)

    # Step 4: Bind the App to the existing client
    bound = LF_BindApp(app.raw)
    if bound == 0:
        print("[Client] WARNING: LF_BindApp returned 0 (no free client). The App may not be reachable.")
    else:
        print(f"[Client] App '{client_name}' bound to {bound} client(s).")
    time.sleep(1)  # short delay before proceeding

    # Step 5: Optionally set system message
    if args.system_message:
        print(f"[Client] Setting system message: {args.system_message[:50]}...")
        resp = remote_call(args.server_app, "set_system_message",
                           {"content": args.system_message}, args.timeout)
        if resp is None or resp.get("code") != 0:
            print("[Client] ERROR: Failed to set system message", file=sys.stderr)
            app.free()
            LF_ExitMainThread()
            LF_Shutdown()
            sys.exit(1)
        print("[Client] System message set successfully.")

    # Step 6: Send generate request with client_name
    request_data = {
        "content": args.content,
        "prompt": args.prompt,
        "client_name": client_name
    }
    print(f"[Client] Sending generation request to {args.server_app} ...")
    result = remote_call(args.server_app, "generate", request_data, args.timeout)
    if result is None:
        print("[Client] ERROR: Generation call failed", file=sys.stderr)
        app.free()
        LF_ExitMainThread()
        LF_Shutdown()
        sys.exit(1)
    print(f"[Client] Generation started, session_id: {result.get('session_id')}")
    print("[Client] Receiving streamed output:")

    # Step 7: Wait for finish signal
    finish_event.wait()
    print("\n[Client] Stream ended. Cleaning up.")

    # Step 8: Cleanup
    app.free()
    LF_ExitMainThread()
    LF_Shutdown()
    print("[Client] Done.")

if __name__ == "__main__":
    main()