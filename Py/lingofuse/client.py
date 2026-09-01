# -*- coding: utf-8 -*-
"""
C4 Client: proxy for remote API calls.

This module provides a high‑level client that connects to a C4 service
and exposes remote APIs as Python methods via __getattr__.

Thread safety:
    - LF_Call() is fully thread‑safe; you can call it from multiple threads.
    - The registered callbacks (if any) run in background threads, so avoid
      blocking operations and calls to LF_Call/LF_Notify inside them.

The client uses a shared global preparation state. Only one C4 instance
should be created per process; subsequent calls will reuse the existing
connection.
"""
from typing import Any, Optional
from ._lf_native import (
    LF_ResetPrepare, LF_PrepareClient, LF_PrepareDone,
    LF_Call, LF_Notify, LF_Sequenced_Notify,
    LF_ExitMainThread, LF_Shutdown,
)
from .core import DataHandle
from .errors import LingoFuseError, ConnectionError, TimeoutError
from .serializers import default_serializer, default_deserializer


class C4:
    """
    Client that connects to a remote LingoFuse service and provides
    dynamic method dispatch for remote calls.

    Usage:
        client = C4("ServiceApp", "ipc:demo_service")
        result = client.add(10, 20)   # Calls remote 'add' API
        client.notify("log", "message")
        client.sequenced_notify("event", {"data": 42})  # FIFO order

    The client is designed as a singleton: only one global connection
    is prepared. Creating multiple C4 instances with different endpoints
    will cause the latter to ignore the new endpoint and reuse the
    first one. This matches the underlying C4 design where preparation
    is done once per process.

    {!!!!!  SHUTDOWN BEHAVIOUR  !!!!!}
    `shutdown()` calls `LF_ExitMainThread()` to stop the network event loop,
    but **does not call `LF_Shutdown()`**. The library remains initialised
    so that new connections can be established later. To perform a full
    library cleanup, call `LF.Shutdown()` directly.
    """
    _global_initialized = False

    def __init__(self, app_name: str, endpoint: str, timeout: int = 5000,
                 serializer=None, deserializer=None):
        self._app_name = app_name
        self._endpoint = endpoint
        self._timeout = timeout
        self._serializer = serializer or default_serializer
        self._deserializer = deserializer or default_deserializer
        self._connect()

    def _connect(self):
        if not C4._global_initialized:
            LF_ResetPrepare()
            LF_PrepareClient(self._endpoint.encode("utf-8"), None)
            ret = LF_PrepareDone()
            if ret != 1:
                raise ConnectionError(
                    f"Connect to {self._endpoint} failed. Check console output for details. "
                    f"(Return code: {ret})"
                )
            C4._global_initialized = True

    def __getattr__(self, api_name: str):
        def _call(*args, **kwargs):
            if len(args) == 1 and not kwargs:
                param_data = args[0]
            else:
                param_data = args if not kwargs else (args, kwargs)
            data = DataHandle(api_name, param_data, self._serializer)
            h_res = LF_Call(self._app_name.encode("utf-8"), data.raw, self._timeout)
            data.free()
            if not h_res:
                raise LingoFuseError(f"Call to {api_name} returned null handle")
            result_hnd = DataHandle._from_raw(h_res, owned=True)
            try:
                result = result_hnd.read(self._deserializer)
            finally:
                result_hnd.free()
            return result
        return _call

    def notify(self, api_name: str, data: Any):
        hnd = DataHandle(api_name, data, self._serializer)
        LF_Notify(self._app_name.encode("utf-8"), hnd.raw)
        hnd.free()

    def sequenced_notify(self, api_name: str, data: Any):
        """
        Send a sequenced notification to the remote application.

        This guarantees FIFO order for the given (app_name, api_name) pair.
        """
        hnd = DataHandle(api_name, data, self._serializer)
        LF_Sequenced_Notify(self._app_name.encode("utf-8"), hnd.raw)
        hnd.free()

    @classmethod
    def shutdown(cls):
        """
        Stop the network event loop and reset the global initialisation flag.

        {!!!!!  IMPORTANT  !!!!!}
        This method calls `LF_ExitMainThread()` to stop the C4 progress loop,
        but **does not call `LF_Shutdown()`**. The library remains loaded and
        can be re‑initialised with a new `C4` instance. To fully unload the
        library and release all resources, call `LF.Shutdown()`.
        """
        if cls._global_initialized:
            LF_ExitMainThread()
            cls._global_initialized = False