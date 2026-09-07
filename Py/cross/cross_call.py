#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""
CrossCall – Concurrent Client (Consumer)

Connects to ipc:cross, alternates between 'add' and 'inv_seri' calls in
a separate thread for 10 seconds then exits. Multiple instances can be
run to simulate load. Equivalent to Pascal cross_call.
"""
import sys
import os
import time
import random
import threading

sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..'))

from lingofuse import _lf_native
from lingofuse.core import DataHandle


# ========== Remote call wrappers (raw binary) ==========

def add__(a, b):
    """Wrapper for remote 'add' call."""
    with DataHandle("add") as send:
        send.write_int32(a)
        send.write_int32(b)

        res_ptr = _lf_native.LF_Call(b"demo", send.raw, 2000)
        if not res_ptr:
            print(f"[Call] add({a}, {b}) returned null handle")
            return 0

        size = _lf_native.LF_GetSize(res_ptr)
        if size == 0:
            _lf_native.LF_FreeData(res_ptr)
            print(f"[Call] add({a}, {b}) timed out or failed")
            return 0

        with DataHandle._from_raw(res_ptr, owned=True) as result:
            return result.read_int32()


def inv_seri__():
    """Wrapper for remote 'inv_seri' call."""
    b = 200
    w = 0x10
    c = 0x2F
    u64 = 0x3F
    s = "hello world"
    f = 3.14

    with DataHandle("inv_seri") as send:
        send.write_uint8(b)
        send.write_uint16(w)
        send.write_uint32(c)
        send.write_uint64(u64)
        send.write_string(s)          # auto \0
        send.write_single(f)

        res_ptr = _lf_native.LF_Call(b"demo", send.raw, 2000)
        if not res_ptr:
            return "inv_seri returned null handle"

        size = _lf_native.LF_GetSize(res_ptr)
        if size == 0:
            _lf_native.LF_FreeData(res_ptr)
            return "inv_seri timed out or failed"

        with DataHandle._from_raw(res_ptr, owned=True) as result:
            f_ret = result.read_single()
            s_ret = result.read_string()          # auto strips \0
            u64_ret = result.read_uint64()
            c_ret = result.read_uint32()
            w_ret = result.read_uint16()
            b_ret = result.read_uint8()

            return (f"Received data sequence [{b_ret}, {w_ret}, {c_ret}, {u64_ret}, \"{s_ret}\", {f_ret:.2f}] = "
                    f"Sent data sequence [{f_ret:.2f}, \"{s_ret}\", {u64_ret}, {c_ret}, {w_ret}, {b_ret}]")


# ========== Worker thread ==========

RUN_DURATION = 10  # seconds

def do_compute(stop_event):
    start_time = time.time()
    print(f"[Call] Simulation started (can be multi‑instanced), running for {RUN_DURATION} seconds...")
    while not stop_event.is_set() and (time.time() - start_time) < RUN_DURATION:
        if random.choice([True, False]):
            a = random.randint(1, 2**31 - 1)
            b = random.randint(1, 2**31 - 1)
            result = add__(a, b)
            if result != 0:
                remaining = RUN_DURATION - (time.time() - start_time)
                print(f"[Call] Computation \"a({a})+b({b})\" = result {result} ({remaining:.2f}s remaining)")
        else:
            status = inv_seri__()
            remaining = RUN_DURATION - (time.time() - start_time)
            print(f"[Call] {status} ({remaining:.2f}s remaining)")

        time.sleep(0.001)


def main():
    print("=== CrossCall (Python) – Concurrent Client ===")

    import atexit
    def cleanup():
        print("[Shutdown] Exiting main thread and shutting down.")
        _lf_native.LF_ExitMainThread()
        _lf_native.LF_Shutdown()
    atexit.register(cleanup)

    try:
        _lf_native.LF_ResetPrepare()
        _lf_native.LF_PrepareClient(b"ipc:cross", None)

        if _lf_native.LF_PrepareDone() != 1:
            print("[ERROR] prepareDone() failed. Check console output.")
            return
        print("[OK] Connected to ipc:cross")

        stop_event = threading.Event()
        thread = threading.Thread(target=do_compute, args=(stop_event,))
        thread.daemon = True
        thread.start()

        time.sleep(RUN_DURATION + 0.5)
        stop_event.set()
        thread.join(timeout=2)

        print("[OK] Computation finished, cleaning up threads.")

    except KeyboardInterrupt:
        print("\n[INFO] Interrupted by user.")
    except Exception as e:
        print(f"[FATAL] Unexpected error: {e}")
        import traceback
        traceback.print_exc()
    finally:
        cleanup()
        print("[OK] Client shutdown complete.")


if __name__ == "__main__":
    main()