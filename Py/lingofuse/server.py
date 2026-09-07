# -*- coding: utf-8 -*-
"""
Server: expose Python functions as remote APIs.

This module provides a high-level Server class that simplifies exposing
Python functions as LingoFuse remote APIs. The Server automatically
manages the underlying App lifecycle and network connections.

{!!!!!  RESOURCE CLEANUP  !!!!!}
- `stop()` stops the network loop and frees the App, but **does not** call
  LF_Shutdown by default (use `stop(full_cleanup=True)` or `full_cleanup()`
  for complete resource release).
- `full_cleanup()` stops the loop, frees the App, and calls LF_Shutdown.
- The `__del__` destructor calls `stop()` as a safety net, but explicit
  cleanup is strongly recommended.
"""
import json
import ctypes
import inspect
import base64
from typing import Any, Callable, Optional, Union, List

from .core import App, DataHandle
from ._lf_native import (
    LF_ResetPrepare, LF_PrepareService, LF_PrepareClient,
    LF_PrepareDone, LF_Call, LF_Notify, LF_Sequenced_Notify,
    LF_ExitMainThread, LF_Shutdown,
    LF_FreeData, LF_CreateData,
)
from .errors import LingoFuseError, ConnectionError

# ----------------------------------------------------------------------
# Internal serialization helpers – now using DataHandle methods
# ----------------------------------------------------------------------
def _convert_to_serializable(obj):
    """Recursively convert bytes to a JSON-serializable dict."""
    if isinstance(obj, bytes):
        return {"__bytes__": base64.b64encode(obj).decode("ascii")}
    elif isinstance(obj, list):
        return [_convert_to_serializable(item) for item in obj]
    elif isinstance(obj, dict):
        return {k: _convert_to_serializable(v) for k, v in obj.items()}
    else:
        return obj

def _convert_from_serializable(obj):
    """Recursively convert a dict containing __bytes__ back to bytes."""
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

def _read_json(hnd: DataHandle):
    """Read JSON from a DataHandle using its built-in read_json."""
    return hnd.read_json()

def _write_json(hnd: DataHandle, obj):
    """Write a Python object as JSON to a DataHandle using its built-in write_json."""
    serializable = _convert_to_serializable(obj)
    hnd.write_json(serializable)


class Server:
    """
    Server that registers APIs via decorators and starts a C4 service.

    The server automatically registers itself as a client to the same
    endpoint, allowing the application to be discovered.

    {!!!!!  BEHAVIOUR NOTE  !!!!!}
    - `start()` and `start_multi()` call `LF_ResetPrepare()` internally,
      which **clears all previously prepared services and clients**.
      If you need to listen on multiple addresses, use `start_multi()`
      with a list of addresses in one call.
    - `stop()` only calls `LF_ExitMainThread()` and frees the App, but
      **does not shut down the library** (no `LF_Shutdown`). The library
      remains initialised and you can call `start()` again later.
    - Use `full_cleanup()` to completely unload the library.

    {!!!!!  APP LIFETIME  !!!!!}
    - `App.free()` (called by `stop()`) detaches the application from all
      clients and stops its sequenced threads, but the underlying object
      remains in the global pool until `LF_Shutdown()` is called.
      If you need immediate memory release, use `full_cleanup()` or call
      `LF_Shutdown()` directly.

    {!!!!!  CLIENT ADDRESS UNIQUENESS  !!!!!}
    - The server internally calls `LF_PrepareClient` with the service
      address. If you call `start()` multiple times with the same address,
      the second call will fail because a client already exists on that
      address. To run multiple clients, use different addresses (e.g.,
      different IPC names or ports).
    """

    def __init__(self, app_name: str, description: str = "", debug: bool = False):
        """
        Create a new Server instance.

        Args:
            app_name: Application name (must be unique in the network).
            description: Human-readable description.
            debug: Enable debug logging.
        """
        self._app = App(app_name, description)
        self._running = False
        self._debug = debug

    def _log(self, msg: str) -> None:
        """Print debug log if enabled."""
        if self._debug:
            print(f"[Server DEBUG] {msg}")

    def expose(self, api_name: str, notify: bool = False, description: str = ""):
        def decorator(func: Callable):
            if notify:
                def _notify_adapter(trigger, inp: DataHandle):
                    try:
                        data = _read_json(inp)
                        sig = inspect.signature(func)
                        params = list(sig.parameters.values())
                        if data is None:
                            func()
                        elif len(params) == 1:
                            if isinstance(data, list) and len(data) == 1:
                                func(data[0])
                            else:
                                func(data)
                        else:
                            if isinstance(data, list):
                                if len(data) == len(params):
                                    func(*data)
                                else:
                                    func(data)
                            elif isinstance(data, dict):
                                func(**data)
                            else:
                                func(data)
                    except Exception as e:
                        if self._debug:
                            print(f"[Server] Notify callback error: {e}")
                self._app.register_notify(api_name, _notify_adapter, description)
            else:
                def _call_adapter(trigger, inp: DataHandle, out: DataHandle):
                    try:
                        data = _read_json(inp)
                        sig = inspect.signature(func)
                        params = list(sig.parameters.values())
                        if data is None:
                            result = func()
                        elif len(params) == 1:
                            if isinstance(data, list) and len(data) == 1:
                                result = func(data[0])
                            else:
                                result = func(data)
                        else:
                            if isinstance(data, list):
                                if len(data) == len(params):
                                    result = func(*data)
                                else:
                                    result = func(data)
                            elif isinstance(data, dict):
                                result = func(**data)
                            else:
                                result = func(data)
                        _write_json(out, result)
                    except Exception as e:
                        error_obj = {"__error__": str(e), "__type__": type(e).__name__}
                        _write_json(out, error_obj)
                        if self._debug:
                            print(f"[Server] Call adapter error: {e}")
                self._app.register_call(api_name, _call_adapter, description)
            return func
        return decorator

    def start(self, addr: str, public_addr: Optional[str] = None):
        """
        Start the C4 service on a single address.

        This method **resets all prepared services/clients** before adding
        the new service and its client. If you need multiple addresses,
        use `start_multi()` instead.

        Important: This method internally calls LF_PrepareClient(addr, ...).
        The same address cannot be reused in another call to start()
        (or any other client preparation) because the underlying library
        prohibits duplicate client addresses. To run multiple servers,
        use distinct addresses.

        Args:
            addr: Local binding address (e.g., "0.0.0.0:9898" or "ipc:my_service").
            public_addr: Public address advertised to clients. Defaults to `addr`.

        Raises:
            ConnectionError: If the service fails to start.
        """
        if self._running:
            print("[Server] Already running, ignoring start() call")
            return
        public_addr = public_addr or addr
        self._log(f"Preparing service on {addr} (public: {public_addr})")
        LF_ResetPrepare()
        serv_ret = LF_PrepareService(addr.encode("utf-8"), public_addr.encode("utf-8"))
        if serv_ret == -1:
            raise ConnectionError(
                f"LF_PrepareService returned -1 for address '{addr}'. "
                "Address may be a duplicate or invalid."
            )
        client_ret = LF_PrepareClient(addr.encode("utf-8"), self._app.raw)
        if client_ret == -1:
            raise ConnectionError(
                f"LF_PrepareClient returned -1 for address '{addr}'. "
                "Address may already be in use by another client."
            )
        ret = LF_PrepareDone()
        if ret != 1:
            # Check if main thread is active despite error
            from ._lf_native import LF_CheckMainThread
            if LF_CheckMainThread() != 0:
                self._log("Warning: LF_PrepareDone returned non-1, but main thread is active. Continuing anyway.")
                # 记录警告但继续，因为有些情况下服务仍部分可用
            else:
                raise ConnectionError(
                    f"Server start failed. Check console output for details. "
                    f"(Return code: {ret})"
                )
        self._running = True
        print(f"[OK] Server '{self._app.name}' started on {addr}")

    def start_multi(self, addresses: Union[str, List[str]], public_addrs: Optional[Union[str, List[str]]] = None):
        """
        Start the C4 service on multiple addresses simultaneously.

        This method **resets all prepared services/clients** and then
        prepares all given services and clients in one batch.

        Note that each address must be unique; duplicates will cause
        LF_PrepareClient to return -1 and log an error.

        Args:
            addresses: A single address string or a list of address strings.
            public_addrs: Optional. If None, each listening address is used
                as its own public address. If a single string, all services
                advertise that address. If a list, must match `addresses` length.

        Raises:
            ValueError: If public_addrs length mismatches.
            RuntimeError: If server is already running.
            ConnectionError: If the network preparation fails.
        """
        if self._running:
            raise RuntimeError("Server already running. Call stop() first.")

        if isinstance(addresses, str):
            addr_list = [addresses]
        else:
            addr_list = list(addresses)

        if public_addrs is None:
            pub_list = addr_list[:]
        elif isinstance(public_addrs, str):
            pub_list = [public_addrs] * len(addr_list)
        else:
            pub_list = list(public_addrs)
            if len(pub_list) != len(addr_list):
                raise ValueError(
                    f"public_addrs length ({len(pub_list)}) must match "
                    f"addresses length ({len(addr_list)})"
                )

        self._log(f"Preparing multi-service: {addr_list}")
        LF_ResetPrepare()
        failed = False
        for listen, pub in zip(addr_list, pub_list):
            serv_ret = LF_PrepareService(listen.encode('utf-8'), pub.encode('utf-8'))
            if serv_ret == -1:
                print(f"[WARN] LF_PrepareService failed for {listen}")
                failed = True
            client_ret = LF_PrepareClient(pub.encode('utf-8'), self._app.raw)
            if client_ret == -1:
                print(f"[WARN] LF_PrepareClient failed for {pub}")
                failed = True

        if failed:
            print("[WARN] Some services/clients failed to prepare, attempting to start anyway...")

        ret = LF_PrepareDone()
        if ret != 1:
            from ._lf_native import LF_CheckMainThread
            if LF_CheckMainThread() != 0:
                self._log("Warning: LF_PrepareDone returned non-1, but main thread is active. Continuing anyway.")
            else:
                raise ConnectionError(
                    f"Server start_multi failed. Check console output for details. "
                    f"(Return code: {ret})"
                )
        self._running = True
        print(f"[OK] Server '{self._app.name}' started on {addr_list}")

    # ---- JSON-aware methods (explicit) ----
    def json_notify(self, api_name: str, *args):
        """Send a one-way notification with JSON-serialized arguments."""
        if not self._running:
            raise RuntimeError("Server not started")
        if self._app.raw is None:
            raise RuntimeError("App has been freed")
        req = DataHandle(api_name)
        _write_json(req, list(args) if args else None)
        LF_Notify(self._app.name.encode("utf-8"), req.raw)
        req.free()

    def json_sequenced_notify(self, api_name: str, *args):
        """Send a sequenced notification with JSON-serialized arguments."""
        if not self._running:
            raise RuntimeError("Server not started")
        if self._app.raw is None:
            raise RuntimeError("App has been freed")
        req = DataHandle(api_name)
        _write_json(req, list(args) if args else None)
        LF_Sequenced_Notify(self._app.name.encode("utf-8"), req.raw)
        req.free()

    def json_call(self, api_name: str, *args, timeout: int = 5000) -> Any:
        """
        Synchronous call expecting a JSON response.
        Returns the deserialized JSON object.
        """
        if not self._running:
            raise RuntimeError("Server not started")
        if self._app.raw is None:
            raise RuntimeError("App has been freed")
        req = DataHandle(api_name)
        _write_json(req, list(args) if args else None)
        resp_raw = LF_Call(self._app.name.encode("utf-8"), req.raw, timeout)
        req.free()
        if not resp_raw:
            raise LingoFuseError("Call returned null handle")
        resp = DataHandle._from_raw(resp_raw, owned=True)
        try:
            result = resp.read_json()
            if isinstance(result, dict) and "__error__" in result:
                raise RuntimeError(result["__error__"])
            return result
        finally:
            resp.free()

    # ---- Legacy aliases (keep for backward compatibility) ----
    def notify(self, api_name: str, *args):
        return self.json_notify(api_name, *args)

    def sequenced_notify(self, api_name: str, *args):
        return self.json_sequenced_notify(api_name, *args)

    def call(self, api_name: str, *args, timeout: int = 5000) -> Any:
        return self.json_call(api_name, *args, timeout=timeout)

    def stop(self, full_cleanup: bool = False):
        """
        Stop the server and exit the main thread.

        {!!!!!  IMPORTANT  !!!!!}
        - If `full_cleanup=False` (default): calls `LF_ExitMainThread()`,
          stops the network event loop, and calls `App.free()`. The library
          remains initialised for a future restart.
          *Note:* `App.free()` detaches the application from all clients and
          stops its sequenced threads, but the underlying `TLF_App` object
          remains in the global pool until `LF_Shutdown()` is called.
        - If `full_cleanup=True`: additionally calls `LF_Shutdown()` to
          completely unload the library and destroy all remaining objects.

        After calling `stop(full_cleanup=True)`, you must re-prepare the
        network and restart the server with `start()`.

        Args:
            full_cleanup: If True, also call LF_Shutdown to release all resources.
        """
        if not self._running:
            print("[Server] Already stopped")
            return
        self._log("Stopping server...")
        self._running = False
        LF_ExitMainThread()
        self._app.free()
        print("[OK] Server stopped (network loop stopped, App freed)")
        if full_cleanup:
            LF_Shutdown()
            print("[OK] LingoFuse library fully unloaded")

    def full_cleanup(self):
        """
        Completely shut down the server and unload the LingoFuse library.

        This is a convenience wrapper around `stop(full_cleanup=True)`.
        """
        self.stop(full_cleanup=True)

    def __del__(self):
        """
        Destructor: attempts to stop the server as a safety net.

        {!!!!!  IMPORTANT  !!!!!}
        Explicit cleanup is strongly recommended over relying on garbage
        collection. This destructor only stops the network loop and frees
        the App, but does NOT call LF_Shutdown (to avoid interfering with
        other potential users of the library in the same process).
        """
        if self._running:
            try:
                self._log("__del__: stopping server")
                self.stop(full_cleanup=False)
            except Exception:
                pass  # Ignore errors during garbage collection