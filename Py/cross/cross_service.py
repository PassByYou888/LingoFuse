#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""
CrossService – 服务注册中心（信标）
功能：创建 IPC 端点 ipc:cross，作为 C4 服务网格的控制平面。
不注册任何业务 API。节点和客户端通过此端点发现彼此。
与 Pascal cross_service 完全等价。
"""
import sys
import os

# 将上级目录（Py）加入模块搜索路径，以便导入 lingofuse
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