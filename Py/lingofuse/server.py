# -*- coding: utf-8 -*-
"""
Server: expose Python functions as remote APIs.

This module provides a high-level Server class that simplifies exposing
Python functions as LingoFuse remote APIs. The Server automatically
manages the underlying App lifecycle and network connections.

{!!!!!  RESOURCE CLEANUP  !!!!!}
- `stop()` stops the network loop and frees the App, but does NOT call
  LF_Shutdown by default (use `stop(full_cleanup=True)` or
  `full_cleanup()` for complete resource release).
- `stop(full_cleanup=True)` also clears any installed network event
  callbacks before calling LF_Shutdown.
- The `__del__` destructor calls `stop()` as a safety net, but explicit
  cleanup is strongly recommended.

{!!!!!  BUG FIX  !!!!!}
The `start_multi()` method previously used the *public* address as the
target of LF_PrepareClient. When the public address differs from the
local listening address (e.g., listen on 0.0.0.0:9898, advertise
192.168.1.5:9898), this caused the client connection to be established
against the wrong endpoint, leading to timeouts or empty responses.
The correct behaviour is to connect to the LOCAL listening address,
matching what `start()` already does.

{!!!!!  STRING PARAMETERS  !!!!!}
Every string argument passed to an LF_* function from this module is
routed through `lingofuse.lf_io.cstr`, which supplies NUL-terminated
UTF-8 bytes for the c_char_p parameter. This removes the previous
reliance on the hidden NUL byte inside CPython bytes objects and
makes the wire contract explicit.
"""

import base64
import ctypes
import inspect
import json
from typing import Any, Callable, List, Optional, Union

from .core import App, DataHandle
from ._lf_native import (
    LF_ResetPrepare, LF_PrepareService, LF_PrepareClient,
    LF_PrepareDone, LF_Call, LF_Notify, LF_Sequenced_Notify,
    LF_ExitMainThread, LF_Shutdown,
    LF_FreeData, LF_CreateData,
    LF_CheckMainThread,
)
from .errors import LingoFuseError, ConnectionError

# Unified LingoFuse payload I/O.
#
# cstr() is the single source of truth for NUL-terminated UTF-8 bytes
# for every LF_* c_char_p parameter in this package. The Server class
# uses it for LF_PrepareService / LF_PrepareClient / LF_Notify /
# LF_Sequenced_Notify / LF_Call.
#
# Note: the JSON payload I/O of the Server's own json_* methods goes
# through DataHandle.write_json / read_json, which were delegated to
# lf_io in the previous revision. No additional import is needed for
# that path.
from .lf_io import cstr


# ======================================================================
# Internal serialization helpers
# ----------------------------------------------------------------------
# These helpers recursively convert between Python objects and JSON
# shapes that can carry raw bytes. They are used by the `expose`
# decorator and by the json_* methods.
# ======================================================================

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
    """
    Read JSON from a DataHandle using its built-in read_json.

    DataHandle.read_json was delegated to lingofuse.lf_io in a
    previous revision, so this function already benefits from the
    unified serialization and framing policy without further change.
    """
    return hnd.read_json()


def _write_json(hnd: DataHandle, obj):
    """
    Write a Python object as JSON to a DataHandle.

    DataHandle.write_json was delegated to lingofuse.lf_io in a
    previous revision, so this function already benefits from the
    unified serialization and framing policy without further change.
    """
    serializable = _convert_to_serializable(obj)
    hnd.write_json(serializable)


# ======================================================================
# Server
# ======================================================================

class Server:
    """
    Server that registers APIs via decorators and starts a C4 service.

    The server automatically registers itself as a client to the same
    endpoint, allowing the application to be discovered.

    {!!!!!  BEHAVIOUR NOTE  !!!!!}
    - `start()` and `start_multi()` call `LF_ResetPrepare()` internally,
      which clears all previously prepared services and clients. If you
      need to listen on multiple addresses, use `start_multi()` with a
      list of addresses in one call.
    - Both `start()` and `start_multi()` raise RuntimeError if the server
      is already running. They are consistent so that the caller can
      rely on a single error-handling path.
    - `stop()` only calls `LF_ExitMainThread()` and frees the App, but
      does not shut down the library (no LF_Shutdown). The library
      remains initialised and you can call `start()` again later.
    - `stop(full_cleanup=True)` additionally clears network event
      callbacks and calls LF_Shutdown to unload the library.
    - Use `full_cleanup()` as a convenience wrapper for
      `stop(full_cleanup=True)`.

    {!!!!!  APP LIFETIME  !!!!!}
    - `App.free()` (called by `stop()`) detaches the application from
      all clients and stops its sequenced threads, but the underlying
      object remains in the global pool until `LF_Shutdown()` is called.
      If you need immediate memory release, use `full_cleanup()` or
      call `LF_Shutdown()` directly.

    {!!!!!  CLIENT ADDRESS UNIQUENESS  !!!!!}
    - The server internally calls `LF_PrepareClient` with the local
      listening address. If you call `start()` multiple times with the
      same address, the second call will fail because a client already
      exists on that address. To run multiple clients, use different
      addresses (e.g., different IPC names or different ports).
    """

    def __init__(self, app_name: str, description: str = "",
                 debug: bool = False):
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

    # ------------------------------------------------------------------
    # Logging helper
    # ------------------------------------------------------------------

    def _log(self, msg: str) -> None:
        """Print debug log if enabled."""
        if self._debug:
            print(f"[Server DEBUG] {msg}")

    # ------------------------------------------------------------------
    # API registration
    # ------------------------------------------------------------------

    def expose(self, api_name: str, notify: bool = False,
               description: str = ""):
        """
        Decorator: register a Python function as a remote API.

        Args:
            api_name: Unique API name (case-insensitive on the wire).
            notify: If True, register a one-way Notify API; otherwise a
                request-response Call API.
            description: Optional human-readable description.

        The decorated function is called with arguments reconstructed
        from the incoming JSON payload. Supported input shapes:
            - ``None`` / empty payload   -> call with no arguments
            - JSON list                  -> positional args
            - JSON object                -> keyword args
            - single-element list with 1-param function -> unwrap
            - anything else              -> passed as the first argument
        """
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
                        # Adapter-level errors are logged but not
                        # propagated (the callback wrapper in core.py
                        # would catch them anyway).
                        if self._debug:
                            print(
                                f"[Server] Notify adapter error for "
                                f"'{api_name}': {e}"
                            )
                self._app.register_notify(api_name, _notify_adapter,
                                          description)
            else:
                def _call_adapter(trigger, inp: DataHandle,
                                  out: DataHandle):
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
                        error_obj = {
                            "__error__": str(e),
                            "__type__": type(e).__name__,
                        }
                        _write_json(out, error_obj)
                        if self._debug:
                            print(
                                f"[Server] Call adapter error for "
                                f"'{api_name}': {e}"
                            )
                self._app.register_call(api_name, _call_adapter,
                                        description)
            return func
        return decorator

    # ------------------------------------------------------------------
    # Startup
    # ------------------------------------------------------------------

    def start(self, addr: str, public_addr: Optional[str] = None):
        """
        Start the C4 service on a single address.

        This method resets all prepared services/clients before adding
        the new service and its client. If you need multiple addresses,
        use `start_multi()` instead.

        Important: This method internally calls
        `LF_PrepareClient(addr, ...)`. The same address cannot be reused
        in another call to start() (or any other client preparation)
        because the underlying library prohibits duplicate client
        addresses. To run multiple servers, use distinct addresses.

        Args:
            addr: Local binding address (e.g., "0.0.0.0:9898" or
                "ipc:my_service").
            public_addr: Public address advertised to clients.
                Defaults to `addr`.

        Raises:
            RuntimeError: If the server is already running.
            ConnectionError: If the service fails to start.
        """
        if self._running:
            raise RuntimeError(
                "Server already running. Call stop() first."
            )

        public_addr = public_addr or addr
        self._log(f"Preparing service on {addr} (public: {public_addr})")

        LF_ResetPrepare()

        serv_ret = LF_PrepareService(
            cstr(addr),
            cstr(public_addr),
        )
        if serv_ret == -1:
            raise ConnectionError(
                f"LF_PrepareService returned -1 for address '{addr}'. "
                f"Address may be a duplicate or invalid."
            )

        # Connect the internal client to the LOCAL listening address.
        client_ret = LF_PrepareClient(cstr(addr), self._app.raw)
        if client_ret == -1:
            raise ConnectionError(
                f"LF_PrepareClient returned -1 for address '{addr}'. "
                f"Address may already be in use by another client."
            )

        ret = LF_PrepareDone()
        if ret != 1:
            # LF_PrepareDone may return non-1 in a few edge cases even
            # when the main thread is actually running (e.g., partial
            # readiness). We continue in that case, but raise otherwise.
            if LF_CheckMainThread() != 0:
                self._log(
                    "Warning: LF_PrepareDone returned non-1, but the "
                    "main thread is active. Continuing anyway."
                )
            else:
                raise ConnectionError(
                    f"Server start failed. Check console output for "
                    f"details. (Return code: {ret})"
                )

        self._running = True
        print(f"[OK] Server '{self._app.name}' started on {addr}")

    def start_multi(
        self,
        addresses: Union[str, List[str]],
        public_addrs: Optional[Union[str, List[str]]] = None,
    ):
        """
        Start the C4 service on multiple addresses simultaneously.

        This method resets all prepared services/clients and then
        prepares all given services and clients in one batch.

        {!!!!!  ADDRESS SEMANTICS  !!!!!}
        - ``addresses`` are the LOCAL listening addresses.
        - ``public_addrs`` are the addresses advertised to remote
          clients. When they are omitted, each listening address is
          also used as its own public address.
        - The internal client connection is always established against
          the LOCAL listening address (not the public one). This matches
          `start()` and is required for the local client to reach the
          local service.

        Note that each address must be unique; duplicates will cause
        LF_PrepareClient to return -1 and print a warning. In that case,
        the method continues with the remaining addresses.

        Args:
            addresses: A single address string or a list of address
                strings.
            public_addrs: Optional. If None, each listening address is
                used as its own public address. If a single string, all
                services advertise that address. If a list, must match
                `addresses` length.

        Raises:
            RuntimeError: If the server is already running.
            ValueError: If public_addrs length mismatches.
            ConnectionError: If the network preparation fails entirely.
        """
        if self._running:
            raise RuntimeError(
                "Server already running. Call stop() first."
            )

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
            serv_ret = LF_PrepareService(
                cstr(listen),
                cstr(pub),
            )
            if serv_ret == -1:
                print(f"[WARN] LF_PrepareService failed for {listen}")
                failed = True

            # IMPORTANT: connect to the LOCAL listening address,
            # not the public one. This mirrors start() and is required
            # for the local client to be able to reach the local service.
            client_ret = LF_PrepareClient(
                cstr(listen),
                self._app.raw,
            )
            if client_ret == -1:
                print(f"[WARN] LF_PrepareClient failed for {listen}")
                failed = True

        if failed:
            print(
                "[WARN] Some services/clients failed to prepare, "
                "attempting to start anyway..."
            )

        ret = LF_PrepareDone()
        if ret != 1:
            if LF_CheckMainThread() != 0:
                self._log(
                    "Warning: LF_PrepareDone returned non-1, but the "
                    "main thread is active. Continuing anyway."
                )
            else:
                raise ConnectionError(
                    f"Server start_multi failed. Check console output "
                    f"for details. (Return code: {ret})"
                )

        self._running = True
        print(f"[OK] Server '{self._app.name}' started on {addr_list}")

    # ------------------------------------------------------------------
    # JSON-aware methods (explicit)
    # ------------------------------------------------------------------

    def json_notify(self, api_name: str, *args):
        """
        Send a one-way notification with JSON-serialized arguments.

        The app name is passed through lingofuse.lf_io.cstr, which
        supplies the NUL-terminated UTF-8 bytes expected by the
        underlying c_char_p parameter of LF_Notify.
        """
        if not self._running:
            raise RuntimeError("Server not started")
        if self._app.raw is None:
            raise RuntimeError("App has been freed")
        req = DataHandle(api_name)
        try:
            _write_json(req, list(args) if args else None)
            LF_Notify(cstr(self._app.name), req.raw)
        finally:
            req.free()

    def json_sequenced_notify(self, api_name: str, *args):
        """
        Send a sequenced notification with JSON-serialized arguments.

        The app name is passed through lingofuse.lf_io.cstr, which
        supplies the NUL-terminated UTF-8 bytes expected by the
        underlying c_char_p parameter of LF_Sequenced_Notify.
        """
        if not self._running:
            raise RuntimeError("Server not started")
        if self._app.raw is None:
            raise RuntimeError("App has been freed")
        req = DataHandle(api_name)
        try:
            _write_json(req, list(args) if args else None)
            LF_Sequenced_Notify(cstr(self._app.name), req.raw)
        finally:
            req.free()

    def json_call(self, api_name: str, *args, timeout: int = 5000) -> Any:
        """
        Synchronous call expecting a JSON response.

        Returns the deserialized JSON object. If the remote handler
        reported an error via the ``__error__`` convention, raises
        RuntimeError with the original message.

        The app name is passed through lingofuse.lf_io.cstr, which
        supplies the NUL-terminated UTF-8 bytes expected by the
        underlying c_char_p parameter of LF_Call.
        """
        if not self._running:
            raise RuntimeError("Server not started")
        if self._app.raw is None:
            raise RuntimeError("App has been freed")

        req = DataHandle(api_name)
        try:
            _write_json(req, list(args) if args else None)
            resp_raw = LF_Call(
                cstr(self._app.name),
                req.raw,
                timeout,
            )
        finally:
            req.free()

        if not resp_raw:
            raise LingoFuseError("Call returned a null handle")

        resp = DataHandle._from_raw(resp_raw, owned=True)
        try:
            result = resp.read_json()
            if isinstance(result, dict) and "__error__" in result:
                raise RuntimeError(result["__error__"])
            return result
        finally:
            resp.free()

    # ------------------------------------------------------------------
    # Legacy aliases (kept for backward compatibility)
    # ------------------------------------------------------------------

    def notify(self, api_name: str, *args):
        return self.json_notify(api_name, *args)

    def sequenced_notify(self, api_name: str, *args):
        return self.json_sequenced_notify(api_name, *args)

    def call(self, api_name: str, *args, timeout: int = 5000) -> Any:
        return self.json_call(api_name, *args, timeout=timeout)

    # ------------------------------------------------------------------
    # Shutdown
    # ------------------------------------------------------------------

    def stop(self, full_cleanup: bool = False):
        """
        Stop the server and exit the main thread.

        {!!!!!  IMPORTANT  !!!!!}
        - If ``full_cleanup=False`` (default): calls
          ``LF_ExitMainThread()``, stops the network event loop, and
          calls ``App.free()``. The library remains initialised for a
          future restart. Network event callbacks, if any, are left
          untouched so that a subsequent `start()` can reuse them.
        - If ``full_cleanup=True``: additionally clears network event
          callbacks and calls ``LF_Shutdown()`` to completely unload
          the library and destroy all remaining objects.

        After calling ``stop(full_cleanup=True)``, you must re-prepare
        the network and restart the server with ``start()``.

        Args:
            full_cleanup: If True, also call LF_Shutdown to release all
                resources.
        """
        if not self._running:
            print("[Server] Already stopped")
            return

        self._log("Stopping server...")
        self._running = False

        # Clear network event callbacks first, before tearing down the
        # library. This must happen before LF_Shutdown, and it is only
        # done when a full cleanup has been requested. For a plain stop
        # we leave callbacks in place so a subsequent start() can reuse
        # them.
        if full_cleanup:
            try:
                from .network_events import clear_network_event
                clear_network_event()
            except Exception:
                pass

        LF_ExitMainThread()
        self._app.free()
        print("[OK] Server stopped (network loop stopped, App freed)")

        if full_cleanup:
            LF_Shutdown()
            print("[OK] LingoFuse library fully unloaded")

    def full_cleanup(self):
        """
        Completely shut down the server and unload the LingoFuse library.

        This is a convenience wrapper around ``stop(full_cleanup=True)``.
        """
        self.stop(full_cleanup=True)

    # ------------------------------------------------------------------
    # Destructor safety net
    # ------------------------------------------------------------------

    def __del__(self):
        """
        Destructor: attempts to stop the server as a safety net.

        {!!!!!  IMPORTANT  !!!!!}
        Explicit cleanup is strongly recommended over relying on garbage
        collection. This destructor only stops the network loop and frees
        the App, but does NOT call LF_Shutdown (to avoid interfering with
        other potential users of the library in the same process).
        """
        try:
            if self._running:
                self._log("__del__: stopping server")
                self.stop(full_cleanup=False)
        except Exception:
            # Never let destructor exceptions reach the interpreter.
            pass