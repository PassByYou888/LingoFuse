# -*- coding: utf-8 -*-
"""
C4 Client: proxy for remote API calls.

This module provides a high-level client that connects to a C4 service
and exposes remote APIs as Python methods via __getattr__.

Thread safety:
    - LF_Call() is fully thread-safe; you can call it from multiple threads.
    - The registered callbacks (if any) run in background threads, so avoid
      blocking operations and calls to LF_Call/LF_Notify inside them.
    - The global connection state (_global_initialized) is protected by a
      lock, so creating C4 instances from multiple threads is safe.

{!!!!!  SINGLETON CONNECTION  !!!!!}
Only one global connection is prepared per process. Creating multiple C4
instances with different endpoints will cause the latter to ignore the
new endpoint and reuse the first one. This matches the underlying C4
design where preparation is done once per process.

{!!!!!  EXPLICIT CLEANUP REQUIRED  !!!!!}
C4 does NOT define a __del__ safety net. This is intentional: because the
connection is process-global, running cleanup from the destructor of an
arbitrary C4 instance could tear down the connection while other C4
instances are still in use.

You MUST call one of these explicitly when you are done:
    * C4.shutdown()       -- stops the network loop, keeps the library
                             loaded (fast restart)
    * C4.full_cleanup()   -- stops the loop and unloads the library

{!!!!!  ADDRESS UNIQUENESS  !!!!!}
If you call the constructor with an address that has already been used
by a previous C4 instance (even if that instance was shut down), the
second call will fail because LF_PrepareClient cannot reuse addresses.
To create a new connection to the same service after shutdown, use a
different address (e.g., a different port) or restart the entire
framework.
"""

import threading
from typing import Any, Optional

from ._lf_native import (
    LF_ResetPrepare, LF_PrepareClient, LF_PrepareDone,
    LF_Call, LF_Notify, LF_Sequenced_Notify,
    LF_ExitMainThread, LF_Shutdown,
)
from .core import DataHandle
from .errors import LingoFuseError, ConnectionError, TimeoutError
from .serializers import default_serializer, default_deserializer


# ======================================================================
# C4
# ======================================================================

class C4:
    """
    Client that connects to a remote LingoFuse service and provides
    dynamic method dispatch for remote calls.

    Usage:
        client = C4("ServiceApp", "ipc:demo_service")
        result = client.add(10, 20)   # Calls remote 'add' API
        client.notify("log", "message")
        client.sequenced_notify("event", {"data": 42})  # FIFO order

    {!!!!!  DYNAMIC ATTRIBUTE LOOKUP  !!!!!}
    Any attribute access that does not match an existing method or
    instance attribute is treated as a remote API name, and a callable
    is returned. To avoid interfering with Python's introspection
    protocols (hasattr, copy, inspect, pickle, ...), attribute names
    starting with an underscore are NOT intercepted and raise
    AttributeError as usual.

    {!!!!!  SHUTDOWN BEHAVIOUR  !!!!!}
    `shutdown()` stops the network event loop but does NOT unload the
    library. `full_cleanup()` additionally calls LF_Shutdown.
    Both methods also clear any installed network event callbacks.

    See the module docstring for the full rationale on explicit cleanup.
    """

    # Global connection state, protected by _global_lock.
    _global_initialized = False
    _global_lock = threading.Lock()
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
        """
        Initialize the process-global connection, if not already done.

        Guarded by _global_lock so that concurrent construction of
        multiple C4 instances from different threads does not race
        on the initialization sequence.
        """
        with C4._global_lock:
            if C4._global_initialized:
                self._log(f"Reusing existing connection to {self._endpoint}")
                return

            self._log(f"Initializing connection to {self._endpoint}")
            LF_ResetPrepare()

            ret = LF_PrepareClient(self._endpoint.encode("utf-8"), None)
            if ret == -1:
                # This may happen if the address was already used or is
                # malformed. Since we hold the global lock, no other
                # thread can have created a client in the meantime.
                raise ConnectionError(
                    f"LF_PrepareClient returned -1 for endpoint "
                    f"'{self._endpoint}'. Address may already be in use "
                    f"or invalid."
                )

            ret_ready = LF_PrepareDone()
            if ret_ready != 1:
                # Check if main thread is active despite error.
                from ._lf_native import LF_CheckMainThread
                if LF_CheckMainThread() != 0:
                    self._log(
                        "Warning: LF_PrepareDone returned non-1, but the "
                        "main thread is active. Continuing anyway."
                    )
                else:
                    raise ConnectionError(
                        f"Connect to {self._endpoint} failed. "
                        f"Check console output for details. "
                        f"(Return code: {ret_ready})"
                    )

            C4._global_initialized = True
            self._log(f"Connected to LingoFuse service: {self._endpoint}")

    # ------------------------------------------------------------------
    # Dynamic attribute lookup
    # ------------------------------------------------------------------

    def __getattr__(self, api_name: str):
        # Reject names that start with an underscore so that Python's
        # introspection protocols (hasattr, copy, inspect, pickle, ...)
        # continue to behave as expected and do not mistake the client
        # for an object exposing arbitrary private attributes.
        if api_name.startswith("_"):
            raise AttributeError(
                f"{type(self).__name__!r} object has no attribute "
                f"{api_name!r}"
            )

        def _call(*args, **kwargs):
            # If exactly one positional argument and no keyword args,
            # use it as the payload. Otherwise, pack args and kwargs
            # into a tuple.
            if len(args) == 1 and not kwargs:
                param_data = args[0]
            else:
                param_data = args if not kwargs else (args, kwargs)

            data = DataHandle(api_name, param_data, self._serializer)
            try:
                h_res = LF_Call(
                    self._app_name.encode("utf-8"),
                    data.raw,
                    self._timeout,
                )
            finally:
                data.free()

            if not h_res:
                raise LingoFuseError(
                    f"Call to '{api_name}' returned a null handle"
                )

            result_hnd = DataHandle._from_raw(
                h_res,
                owned=True,
                serializer=self._serializer,
                deserializer=self._deserializer,
            )
            try:
                return result_hnd.read(self._deserializer)
            finally:
                result_hnd.free()

        return _call

    # ------------------------------------------------------------------
    # Explicit JSON methods
    # ------------------------------------------------------------------

    def json_notify(self, api_name: str, data: Any):
        """Send a one-way notification with a serialized payload."""
        hnd = DataHandle(api_name, data, self._serializer)
        try:
            LF_Notify(self._app_name.encode("utf-8"), hnd.raw)
        finally:
            hnd.free()

    def json_sequenced_notify(self, api_name: str, data: Any):
        """
        Send a sequenced notification with a serialized payload.

        This guarantees FIFO order for the given (app_name, api_name)
        pair.
        """
        hnd = DataHandle(api_name, data, self._serializer)
        try:
            LF_Sequenced_Notify(self._app_name.encode("utf-8"), hnd.raw)
        finally:
            hnd.free()

    def json_call(self, api_name: str, data: Any) -> Any:
        """Synchronous JSON call: returns deserialized JSON response."""
        hnd = DataHandle(api_name, data, self._serializer)
        try:
            h_res = LF_Call(
                self._app_name.encode("utf-8"),
                hnd.raw,
                self._timeout,
            )
        finally:
            hnd.free()

        if not h_res:
            raise LingoFuseError(
                f"Call to '{api_name}' returned a null handle"
            )

        result_hnd = DataHandle._from_raw(
            h_res,
            owned=True,
            serializer=self._serializer,
            deserializer=self._deserializer,
        )
        try:
            return result_hnd.read(self._deserializer)
        finally:
            result_hnd.free()

    # ------------------------------------------------------------------
    # Legacy aliases (kept for backward compatibility)
    # ------------------------------------------------------------------

    def notify(self, api_name: str, data: Any):
        return self.json_notify(api_name, data)

    def sequenced_notify(self, api_name: str, data: Any):
        return self.json_sequenced_notify(api_name, data)

    def call(self, api_name: str, data: Any) -> Any:
        return self.json_call(api_name, data)

    # ------------------------------------------------------------------
    # Cleanup
    # ------------------------------------------------------------------

    @classmethod
    def shutdown(cls):
        """
        Stop the network event loop and reset the global initialisation flag.

        {!!!!!  IMPORTANT  !!!!!}
        This method calls `LF_ExitMainThread()` to stop the C4 progress
        loop, but does NOT call `LF_Shutdown()`. The library remains
        loaded and can be re-initialised with a new C4 instance.

        This method also clears any installed network event callbacks
        so that stale Python callbacks do not remain referenced after
        the loop has stopped.

        To fully unload the library and release all resources, use
        `C4.full_cleanup()` or call `LF_Shutdown()` directly.
        """
        # Clear network event callbacks first, so that no user callback
        # can fire during the shutdown transition.
        try:
            from .network_events import clear_network_event
            clear_network_event()
        except Exception:
            # Defensive: never let cleanup of an unrelated subsystem
            # block the shutdown path.
            pass

        with cls._global_lock:
            if cls._global_initialized:
                print(
                    "[C4] Stopping network event loop "
                    "(library remains loaded)"
                )
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
            1. Clears installed network event callbacks.
            2. Stops the network event loop.
            3. Calls LF_Shutdown to release all library resources.
            4. Resets the global initialisation flag.

        After calling full_cleanup(), you can re-initialise the library
        by creating a new C4 instance (with a different endpoint address,
        as the previous one cannot be reused).
        """
        try:
            from .network_events import clear_network_event
            clear_network_event()
        except Exception:
            pass

        with cls._global_lock:
            if cls._global_initialized:
                print(
                    "[C4] Performing full cleanup: stopping loop and "
                    "shutting down library"
                )
                LF_ExitMainThread()
                LF_Shutdown()
                cls._global_initialized = False
                print("[C4] Full cleanup complete")
            else:
                # Even if the client is not marked as initialized, we
                # still call LF_Shutdown so that the library state is
                # reset consistently. LF_Shutdown is safe to call
                # multiple times.
                try:
                    LF_Shutdown()
                except Exception:
                    pass
                print("[C4] Not initialised, library shut down anyway")