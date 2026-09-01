# -*- coding: utf-8 -*-
"""
Server: expose Python functions as remote APIs.
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
    LF_WriteBuffer, LF_ReadBuffer, LF_GetSize, LF_SetPos,
)
from .errors import LingoFuseError, ConnectionError

# ----------------------------------------------------------------------
# Internal serialization helpers
# ----------------------------------------------------------------------
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
    size = LF_GetSize(hnd.raw)
    if size == 0:
        return None
    buf = (ctypes.c_byte * size)()
    LF_SetPos(hnd.raw, 0)
    LF_ReadBuffer(hnd.raw, buf, size)
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
    LF_WriteBuffer(hnd.raw, data, len(data))


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
    - `stop()` only calls `LF_ExitMainThread()`, which stops the network
      event loop but **does not shut down the library**. The library remains
      initialised and you can call `start()` again later. For a full cleanup,
      call `LF.Shutdown()` after stopping.
    """

    def __init__(self, app_name: str, description: str = ""):
        self._app = App(app_name, description)
        self._running = False

    def expose(self, api_name: str, notify: bool = False, description: str = ""):
        def decorator(func: Callable):
            if notify:
                def _notify_adapter(trigger, inp):
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
                    except Exception:
                        pass
                self._app.register_notify(api_name, _notify_adapter, description)
            else:
                def _call_adapter(trigger, inp, out):
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
                self._app.register_call(api_name, _call_adapter, description)
            return func
        return decorator

    def start(self, addr: str, public_addr: Optional[str] = None):
        """
        Start the C4 service on a single address.

        This method **resets all prepared services/clients** before adding
        the new service and its client. If you need multiple addresses,
        use `start_multi()` instead.

        Args:
            addr: Local binding address (e.g., "0.0.0.0:9898" or "ipc:my_service").
            public_addr: Public address advertised to clients. Defaults to `addr`.

        Raises:
            ConnectionError: If the service fails to start.
        """
        if self._running:
            return
        public_addr = public_addr or addr
        # Ensure a clean network state before starting
        LF_ResetPrepare()
        LF_PrepareService(addr.encode("utf-8"), public_addr.encode("utf-8"))
        LF_PrepareClient(addr.encode("utf-8"), self._app.raw)
        ret = LF_PrepareDone()
        if ret != 1:
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

        LF_ResetPrepare()
        for listen, pub in zip(addr_list, pub_list):
            LF_PrepareService(listen.encode('utf-8'), pub.encode('utf-8'))
            LF_PrepareClient(pub.encode('utf-8'), self._app.raw)

        ret = LF_PrepareDone()
        if ret != 1:
            raise ConnectionError(
                f"Server start_multi failed. Check console output for details. "
                f"(Return code: {ret})"
            )
        self._running = True
        print(f"[OK] Server '{self._app.name}' started on {addr_list}")

    def notify(self, api_name: str, *args):
        if not self._running:
            raise RuntimeError("Server not started")
        req = LF_CreateData(api_name.encode("utf-8"))
        _write_json(DataHandle._from_raw(req, owned=False), list(args) if args else None)
        LF_Notify(self._app.name.encode("utf-8"), req)
        LF_FreeData(req)

    def sequenced_notify(self, api_name: str, *args):
        if not self._running:
            raise RuntimeError("Server not started")
        req = LF_CreateData(api_name.encode("utf-8"))
        _write_json(DataHandle._from_raw(req, owned=False), list(args) if args else None)
        LF_Sequenced_Notify(self._app.name.encode("utf-8"), req)
        LF_FreeData(req)

    def call(self, api_name: str, *args, timeout: int = 5000) -> Any:
        if not self._running:
            raise RuntimeError("Server not started")
        req = LF_CreateData(api_name.encode("utf-8"))
        _write_json(DataHandle._from_raw(req, owned=False), list(args) if args else None)
        resp = LF_Call(self._app.name.encode("utf-8"), req, timeout)
        LF_FreeData(req)
        if not resp:
            raise LingoFuseError("Call returned null handle")
        try:
            result = _read_json(DataHandle._from_raw(resp, owned=False))
            if isinstance(result, dict) and "__error__" in result:
                raise RuntimeError(result["__error__"])
            return result
        finally:
            LF_FreeData(resp)

    def stop(self):
        """
        Stop the server and exit the main thread.

        {!!!!!  IMPORTANT  !!!!!}
        This method only calls `LF_ExitMainThread()`, which stops the network
        event loop but **does not shut down the library** (no `LF_Shutdown`).
        The library remains initialised, allowing you to call `start()` again
        later (with a new set of addresses). To fully clean up resources and
        allow a fresh start from scratch, call `LF.Shutdown()` after stopping.
        """
        if not self._running:
            return
        self._running = False
        LF_ExitMainThread()
        self._app.free()
        print("[OK] Server stopped")