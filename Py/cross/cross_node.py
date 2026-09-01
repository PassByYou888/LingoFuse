#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""
CrossNode – 无状态工作节点（Worker）
功能：注册应用 'demo'，暴露 'add' 和 'inv_seri' 两个 Call API。
使用 LF_SetOption("Wait_Connection_ReadyOk", "False") 启用部署模式，
允许节点先于服务启动（自动重连）。
与 Pascal cross_node 完全等价。
"""
import sys
import os

# 将上级目录（Py）加入模块搜索路径
sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..'))

from lingofuse import _lf_native
from lingofuse.core import App, DataHandle
from lingofuse.errors import RegistrationError


# ========== 回调函数（原始二进制，无 JSON） ==========

def add_callback(trigger, inp, out):
    """'add' 回调：读取两个 Int32，返回它们的和（模拟 32 位有符号溢出）。"""
    try:
        a = inp.read_int32()
        b = inp.read_int32()
        c = (a + b) & 0xFFFFFFFF
        if c >= 0x80000000:
            c -= 0x100000000
        print(f"[Node] add({a}, {b}) = {c}")
        out.write_int32(c)
    except Exception as e:
        print(f"[ERROR] add_callback: {e}")


def inv_seri_callback(trigger, inp, out):
    """'inv_seri' 回调：接收 6 种不同类型的参数，反向回复。"""
    try:
        b = inp.read_uint8()
        w = inp.read_uint16()
        c = inp.read_uint32()
        u64 = inp.read_uint64()
        s = inp.read_string_null_terminated()
        f = inp.read_single()

        out.write_single(f)
        out.write_string_null_terminated(s)
        out.write_uint64(u64)
        out.write_uint32(c)
        out.write_uint16(w)
        out.write_uint8(b)

        print(f"[Node] inv_seri 接收: [{b}, {w}, {c}, {u64}, \"{s}\", {f:.2f}] "
              f"回复: [{f:.2f}, \"{s}\", {u64}, {c}, {w}, {b}]")
    except Exception as e:
        print(f"[ERROR] inv_seri_callback: {e}")


def main():
    print("=== CrossNode (Python) – Worker Node ===")

    import atexit
    def cleanup():
        print("[Shutdown] Exiting main thread and shutting down.")
        _lf_native.LF_ExitMainThread()
        _lf_native.LF_Shutdown()
    atexit.register(cleanup)

    try:
        with App("demo", "Python cross node instance") as app:
            try:
                app.register_call("add", add_callback, "add(int a, int b)")
                app.register_call("inv_seri", inv_seri_callback, "inv_seri()")
                print("[OK] Registered 'add' and 'inv_seri' under app 'demo'")
            except RegistrationError as e:
                print(f"[ERROR] Registration failed: {e}")
                return

            _lf_native.LF_SetOption(b"Wait_Connection_ReadyOk", b"False")

            _lf_native.LF_ResetPrepare()
            _lf_native.LF_PrepareClient(b"ipc:cross", app.raw)

            if _lf_native.LF_PrepareDone() != 1:
                print("[ERROR] prepareDone() failed. Check console output.")
                return

            print("[OK] Node ready on ipc:cross, waiting for requests...")
            print("[INFO] Press Enter to stop this node...")
            input()

    except KeyboardInterrupt:
        print("\n[INFO] Interrupted by user.")
    except Exception as e:
        print(f"[FATAL] Unexpected error: {e}")
        import traceback
        traceback.print_exc()
    finally:
        cleanup()
        print("[OK] Node shutdown complete.")


if __name__ == "__main__":
    main()