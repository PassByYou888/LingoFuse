# -*- coding: utf-8 -*-
"""
C4 Client: proxy for remote API calls.

This module provides a high-level client that connects to a C4 service
and exposes remote APIs as Python methods via __getattr__.

Thread safety:
    - LF_Call() is fully thread-safe; you can call it from multiple threads.
    - The registered callbacks (if any) run in background threads, so avoid
      blocking operations and calls to LF_Call/LF_Notify inside them.

The client uses a shared global preparation state. Only one C4 instance
should be created per process; subsequent calls will reuse the existing
connection.

Note: The underlying LF_PrepareClient cannot be called twice with the same
address. If you attempt to create multiple C4 instances with the same endpoint,
the second will reuse the existing connection (since the global state is
already initialised). To connect to multiple distinct services, you need
different endpoints. To have multiple clients on the same address, use
different addresses (e.g., different ports or IPC names).
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
    library cleanup, call `LF.Shutdown()` directly or use `C4.full_cleanup()`.

    {!!!!!  ADDRESS UNIQUENESS  !!!!!}
    If you call this constructor with an address that has already been used
    by a previous C4 instance (even if that instance was shut down), the
    second call will fail because LF_PrepareClient cannot reuse addresses.
    To create a new connection to the same service after shutdown, you must
    use a different address (e.g., a different port) or restart the entire
    framework.
    """
    _global_initialized = False
    _debug = False

    @classmethod
    def set_debug(cls, enabled: bool = True) -> None:
        """Enable or disable debug logging for the C4 client."""
        cls._debug = enabled

    @classmethod
    def is_initialized(cls) -> bool:
        """Return True if the global connection has been initialized."""
        return cls._global_initialized

    def __init__(self, app_name: str, endpoint: str, timeout: int = 5000,
                 serializer=None, deserializer=None):
        self._app_name = app_name
        self._endpoint = endpoint
        self._timeout = timeout
        self._serializer = serializer or default_serializer
        self._deserializer = deserializer or default_deserializer
        self._connect()

    def _log(self, msg: str) -> None:
        """Print debug log if enabled."""
        if C4._debug:
            print(f"[C4 DEBUG] {msg}")

    def _connect(self):
        if not C4._global_initialized:
            self._log(f"Initializing connection to {self._endpoint}")
            LF_ResetPrepare()
            ret = LF_PrepareClient(self._endpoint.encode("utf-8"), None)
            if ret == -1:
                # This may happen if the address was already used or is malformed
                raise ConnectionError(
                    f"LF_PrepareClient returned -1 for endpoint '{self._endpoint}'. "
                    "Address may already be in use or invalid."
                )
            ret_ready = LF_PrepareDone()
            if ret_ready != 1:
                # Check if main thread is active despite error
                from ._lf_native import LF_CheckMainThread
                if LF_CheckMainThread() != 0:
                    self._log("Warning: LF_PrepareDone returned non-1, but main thread is active. Continuing anyway.")
                else:
                    raise ConnectionError(
                        f"Connect to {self._endpoint} failed. Check console output for details. "
                        f"(Return code: {ret_ready})"
                    )
            C4._global_initialized = True
            self._log(f"Connected to LingoFuse service: {self._endpoint}")
        else:
            self._log(f"Reusing existing connection to {self._endpoint}")

    def __getattr__(self, api_name: str):
        def _call(*args, **kwargs):
            # If exactly one positional argument and no keyword args,
            # use it as the payload. Otherwise, pack args and kwargs into a tuple.
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

    # ---- Explicit JSON methods ----
    def json_notify(self, api_name: str, data: Any):
        """Send a one-way notification with JSON-serialized payload."""
        hnd = DataHandle(api_name, data, self._serializer)
        LF_Notify(self._app_name.encode("utf-8"), hnd.raw)
        hnd.free()

    def json_sequenced_notify(self, api_name: str, data: Any):
        """
        Send a sequenced notification with JSON-serialized payload.

        This guarantees FIFO order for the given (app_name, api_name) pair.
        """
        hnd = DataHandle(api_name, data, self._serializer)
        LF_Sequenced_Notify(self._app_name.encode("utf-8"), hnd.raw)
        hnd.free()

    def json_call(self, api_name: str, data: Any) -> Any:
        """Synchronous JSON call: returns deserialized JSON response."""
        hnd = DataHandle(api_name, data, self._serializer)
        h_res = LF_Call(self._app_name.encode("utf-8"), hnd.raw, self._timeout)
        hnd.free()
        if not h_res:
            raise LingoFuseError(f"Call to {api_name} returned null handle")
        result_hnd = DataHandle._from_raw(h_res, owned=True)
        try:
            return result_hnd.read(self._deserializer)
        finally:
            result_hnd.free()

    # ---- Legacy aliases (keep for backward compatibility) ----
    def notify(self, api_name: str, data: Any):
        return self.json_notify(api_name, data)

    def sequenced_notify(self, api_name: str, data: Any):
        return self.json_sequenced_notify(api_name, data)

    def call(self, api_name: str, data: Any) -> Any:
        return self.json_call(api_name, data)

    @classmethod
    def shutdown(cls):
        """
        Stop the network event loop and reset the global initialisation flag.

        {!!!!!  IMPORTANT  !!!!!}
        This method calls `LF_ExitMainThread()` to stop the C4 progress loop,
        but **does not call `LF_Shutdown()`**. The library remains loaded and
        can be re-initialised with a new `C4` instance. To fully unload the
        library and release all resources, use `C4.full_cleanup()` or call
        `LF.Shutdown()` directly.

        This behaviour allows graceful restart of the network without
        reloading the entire library.
        """
        if cls._global_initialized:
            print("[C4] Stopping network event loop (library remains loaded)")
            LF_ExitMainThread()
            cls._global_initialized = False
            print("[C4] Network event loop stopped")
        else:
            print("[C4] Not initialised, nothing to stop")

    @classmethod
    def full_cleanup(cls):
        """
        Completely shut down the LingoFuse library and release all resources.

        This method:
            1. Stops the network event loop
            2. Calls LF_Shutdown to release all library resources
            3. Resets the global initialisation flag

        After calling full_cleanup(), you can re-initialise the library
        by creating a new C4 instance (with a different endpoint address,
        as the previous one cannot be reused).
        """
        if cls._global_initialized:
            print("[C4] Performing full cleanup: stopping loop and shutting down library")
            LF_ExitMainThread()
            LF_Shutdown()
            cls._global_initialized = False
            print("[C4] Full cleanup complete")
        else:
            print("[C4] Not initialised, nothing to clean up")