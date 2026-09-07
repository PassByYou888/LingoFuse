#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""
CrossService – Service Registry (Beacon)

Creates IPC endpoint ipc:cross as the control plane for the C4 service mesh.
No business APIs are registered. Nodes and clients discover each other via
this endpoint. Equivalent to Pascal cross_service.
"""
import sys
import os

sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..'))

from lingofuse import _lf_native


def main():
    print("=== CrossService (Python) – Service Registry ===")

    import atexit
    def cleanup():
        print("[Shutdown] Exiting main thread and shutting down.")
        _lf_native.LF_ExitMainThread()
        _lf_native.LF_Shutdown()
    atexit.register(cleanup)

    try:
        _lf_native.LF_ResetPrepare()
        _lf_native.LF_PrepareService(b"ipc:cross", b"ipc:cross")

        if _lf_native.LF_PrepareDone() != 1:
            print("[ERROR] prepareDone() failed. Check console output for details.")
            return

        print("[OK] Service registry ready on ipc:cross")
        print("[INFO] Press Enter to stop the service...")
        input()

    except KeyboardInterrupt:
        print("\n[INFO] Interrupted by user.")
    except Exception as e:
        print(f"[FATAL] Unexpected error: {e}")
        import traceback
        traceback.print_exc()
    finally:
        cleanup()
        print("[OK] Service shutdown complete.")


if __name__ == "__main__":
    main()