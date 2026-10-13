# -*- coding: utf-8 -*-
"""
C4 Client: proxy for remote API calls.

This module provides a high-level client that connects to a C4 service
and exposes remote APIs as Python methods via __getattr__.

=========================== THREE ADDRESSING MODES ============================
As of the current revision, the C4 client supports three orthogonal
addressing modes for remote invocation, all sharing the same set of
call shapes:

    client.app("MyApp").call("add", payload)       -- App name
    client.uid(uid_bytes).call("whoami", payload)  -- UID
    client.p2pname("group").notify("log", payload) -- P2PName

The three addressing modes differ only in routing semantics:

    App name    -- routes to a logical App by name. LOCAL-FIRST: if the
                   caller process itself hosts an App with the matching
                   name and API, the call is serviced locally.

    UID         -- routes to a specific session by its 32-byte UID.
                   LOCAL-FIRST, matching App name routing. The UID is
                   regenerated on every TunnelLink, so callers that
                   cache a UID MUST re-probe it after a link loss.

                   {!!!!!  WHERE THE UID COMES FROM  !!!!!}
                   A UID is NOT a property of any handle the caller
                   creates. It is SIDE DATA that the SENDER'S transport
                   layer injects automatically into every request
                   payload before transmission (Pascal side:
                   TC40_LF_Client.Send_* ->
                   TMemory_Param_Tool.Rebuild_UID_and_P2PName). The
                   receiver side therefore sees the sender's UID in
                   the Data_Param of the INPUT handle it receives.

                   To learn a client's own UID, use the "whoami"
                   pattern: register a Call API on the target side
                   whose callback reads the caller's UID from its
                   INPUT handle via ``DataHandle.get_p2p_uid()``, and
                   call it from the client. See
                   ``lingofuse.core.DataHandle.get_p2p_uid`` for the
                   full side-data contract.

    P2PName     -- routes to any client in a user-defined group. NOT
                   local-first: the call is always forwarded to the
                   server for dispatch (the server owns the
                   load-balancing state).

See lingofuse/address.py for the full Target contract.

=========================== CALL SHAPES ============================
Each Target (and the C4 client itself, for the default app) exposes the
following call shapes:

Legacy (blocking or callback-based):

    call(api, payload, timeout_ms=...)
        Blocking request/response. Returns the deserialized result.

    async_call(api, payload, *, on_result, user_data=None)
        Non-blocking with a user-supplied callback. The callback fires
        later on a TCompute worker thread.

    sequenced_call(api, payload, timeout_ms=...)
        Blocking request/response with FIFO ordering per
        (target_key, api) pair.

    notify(api, payload)
        One-way notification. No response, no ordering.

    sequenced_notify(api, payload)
        One-way notification with FIFO ordering per
        (target_key, api) pair.

Modern (Future / asyncio; see lingofuse.async_support):

    call_future(api, payload, timeout_ms=...)
        Non-blocking. Returns a CallFuture that resolves with the
        result. Never blocks the calling thread.

    call_async(api, payload, timeout_ms=...)
        ``async def`` coroutine. Awaits the result. Suitable for use
        with asyncio.

    sequenced_call_future(api, payload, timeout_ms=...)
        Non-blocking, FIFO-ordered. Returns a CallFuture.

    sequenced_call_async(api, payload, timeout_ms=...)
        ``async def`` coroutine for the FIFO-ordered variant.

The modern shapes are the recommended path for new code. They are
built on lingofuse.async_support, which manages the lifetime of every
ctypes callback object safely: timeouts do not cause use-after-free,
dispatch failures do not leak, and callers can distinguish
"cancelled" from "timed out" via ``CallFuture.abandoned``.

=========================== LEGACY METHODS (UNCHANGED) ============================
The following methods predate the three-addressing-mode abstraction
and remain fully supported. They are semantic shortcuts for the
app-name-addressing mode, targeting the default App name the client
was constructed with:

    client.json_call(api, payload)
        == client.app(client.default_app_name).call(api, payload)

    client.json_notify(api, payload)
        == client.app(client.default_app_name).notify(api, payload)

    client.json_sequenced_notify(api, payload)
        == client.app(client.default_app_name).sequenced_notify(api, payload)

    client.call / client.notify / client.sequenced_notify
        aliases for the above.

    client.<dynamic_attribute>(*args, **kwargs)
        dispatches to client.json_call with the attribute name as the
        API name.

Legacy and modern calls can be freely mixed within the same process:
they share the same underlying connection, the same serialization
policy, and the same error handling.

Note on timeout semantics: the legacy ``json_call`` returns whatever
the underlying LF_Call produced, including an empty DataHandle on
timeout, which is then surfaced as ``None``. The modern Target.call
method raises TimeoutError on timeout instead. Callers that rely on
the legacy None-on-timeout behaviour should keep using the legacy
methods.

=========================== THREAD SAFETY ============================
- LF_Call() is fully thread-safe; you can call it from multiple threads.
- The registered callbacks (if any) run in background threads, so avoid
  blocking operations and calls to LF_Call/LF_Notify inside them.
- The global connection state (_global_initialized) is protected by a
  lock, so creating C4 instances from multiple threads is safe.
- The modern call_future / call_async methods are safe to call
  concurrently from any thread and from any asyncio task.

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

{!!!!!  STRING PARAMETERS  !!!!!}
Every string argument passed to an LF_* function from this module is
routed through `lingofuse.lf_io.cstr`, which supplies NUL-terminated
UTF-8 bytes for the c_char_p parameter. This removes the previous
reliance on the hidden NUL byte inside CPython bytes objects and
makes the wire contract explicit.
"""

import asyncio
import threading
from typing import Any, Optional

from ._lf_native import (
    LF_ResetPrepare, LF_PrepareClient, LF_PrepareDone,
    LF_Call, LF_Notify, LF_Sequenced_Notify,
    LF_ExitMainThread, LF_Shutdown,
)
from .address import AppTarget, UIDTarget, P2PNameTarget
from .async_support import CallFuture
from .core import DataHandle
from .errors import LingoFuseError, ConnectionError, TimeoutError
from .serializers import default_serializer, default_deserializer

# Unified LingoFuse payload I/O.
#
# cstr() is the single source of truth for NUL-terminated UTF-8 bytes
# for every LF_* c_char_p parameter in this package. The C4 client
# uses it for LF_PrepareClient / LF_Call / LF_Notify /
# LF_Sequenced_Notify.
#
# Note: the JSON payload I/O of the C4 json_* methods goes through
# DataHandle.write / read (which use the serializers module) or
# DataHandle.write_json / read_json (which were delegated to lf_io in
# a previous revision). No additional import is needed for that path.
from .lf_io import cstr


# ======================================================================
# C4
# ======================================================================

class C4:
    """
    Client that connects to a remote LingoFuse service and provides
    dynamic method dispatch for remote calls.

    Usage::

        client = C4("ServiceApp", "ipc:demo_service")

        # Legacy dynamic-attribute dispatch:
        result = client.add(10, 20)

        # Legacy explicit methods:
        client.notify("log", "message")
        client.sequenced_notify("event", {"data": 42})

        # Modern addressing modes (share the same connection):
        client.app("OtherApp").call("api", payload)
        client.uid(uid_bytes).call("api", payload)
        client.p2pname("group").notify("api", payload)

        # Modern async (Future / asyncio):
        future = client.call_future("add", {"a": 1, "b": 2})
        result = future.result()

        async def main():
            result = await client.call_async("add", {"a": 1, "b": 2})
            print(result)

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

    {!!!!!  STRING PARAMETERS  !!!!!}
    Every string argument passed to an LF_* function from this class
    is routed through `lingofuse.lf_io.cstr`, which supplies
    NUL-terminated UTF-8 bytes for the c_char_p parameter.
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
        # ``app_name`` is the DEFAULT TARGET app name used by the legacy
        # shortcuts (json_call / json_notify / json_sequenced_notify /
        # __getattr__ dispatch) and by the modern top-level shortcuts
        # (call_future / call_async / sequenced_call_future /
        # sequenced_call_async / sequenced_call). It is not the
        # client's own identity. Use ``app()`` / ``uid()`` /
        # ``p2pname()`` for explicit addressing.
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

            # cstr() supplies the NUL-terminated UTF-8 bytes expected
            # by the c_char_p parameter of LF_PrepareClient.
            ret = LF_PrepareClient(cstr(self._endpoint), None)
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

    # ==================================================================
    # Public read-only properties
    # ==================================================================

    @property
    def default_app_name(self) -> str:
        """
        The default target App name this client was constructed with.

        This is the routing key used by the legacy shortcuts
        (json_call / json_notify / json_sequenced_notify), by the
        dynamic-attribute dispatch path, and by the modern top-level
        shortcuts (call_future / call_async / sequenced_call_future /
        sequenced_call_async / sequenced_call). It is NOT the client's
        own identity: the C ABI does not assign an app name to a
        client implicitly. See ``client.app(name)`` for explicit
        addressing.
        """
        return self._app_name

    @property
    def endpoint(self) -> str:
        """
        The physical endpoint this client connects to.

        This is the address passed to the constructor. It is the same
        value the underlying LF_PrepareClient call used, so it reflects
        the actually-connected endpoint (as opposed to any logical
        address a caller might have intended).
        """
        return self._endpoint

    @property
    def timeout_ms(self) -> int:
        """
        The default timeout in milliseconds.

        Used by the legacy shortcuts, by every Target constructed
        through ``self.app()`` / ``self.uid()`` / ``self.p2pname()``,
        and by the modern top-level shortcuts.
        """
        return self._timeout

    # ==================================================================
    # Modern addressing constructors
    # ------------------------------------------------------------------
    # Each returns an immutable Target object that shares the client's
    # serializer, deserializer, and default timeout. Targets are
    # lightweight and can be constructed on every call; there is no
    # caching overhead worth worrying about.
    # ==================================================================

    def app(self, app_name: str) -> AppTarget:
        """
        Return a Target that addresses a logical App by name.

        Routing is LOCAL-FIRST: if the caller process itself hosts an
        App with the matching name and the requested API, the call is
        serviced locally without touching the network.

        Args:
            app_name: the target App name (UTF-8).

        Returns:
            An AppTarget sharing this client's connection settings.
        """
        return AppTarget(
            app_name,
            serializer=self._serializer,
            deserializer=self._deserializer,
            default_timeout_ms=self._timeout,
        )

    def uid(self, uid) -> UIDTarget:
        """
        Return a Target that addresses a specific session by its UID.

        The UID can address ANY API registered on the target -- whether
        app-bound (via ``App.register_call``) or process-wide (via
        ``lingofuse.register_p2p_call``) -- without requiring the caller
        to know the target App name.

        Routing is LOCAL-FIRST, matching App name routing. The UID is
        regenerated on every TunnelLink, so callers that cache a UID
        must re-probe it after a link loss.

        {!!!!!  WHERE THE UID COMES FROM (SIDE DATA)  !!!!!}
        The UID passed to this method is a VALUE the caller already
        possesses. It is NOT a property of any handle the caller
        creates. The framework injects the UID as "side data" on the
        SENDER side of every request (Pascal side:
        TC40_LF_Client.Send_* ->
        TMemory_Param_Tool.Rebuild_UID_and_P2PName), so the receiving
        side sees the sender's UID in the Data_Param of the INPUT
        handle it receives.

        To learn a client's own UID, use the "whoami" pattern: register
        a Call API on the target side whose callback reads the caller's
        UID from its INPUT handle via ``DataHandle.get_p2p_uid()``.
        The client then calls ``whoami`` and caches the returned
        32-byte value. See ``lingofuse.core.DataHandle.get_p2p_uid``
        for the full side-data contract, including why the accessor
        works only on INPUT handles.

        Args:
            uid: 32-byte UID as bytes / bytearray / memoryview, or a
                 64-character hexadecimal string.

        Returns:
            A UIDTarget sharing this client's connection settings.

        Raises:
            ValueError / TypeError: if ``uid`` is not a valid UID.
        """
        return UIDTarget(
            uid,
            serializer=self._serializer,
            deserializer=self._deserializer,
            default_timeout_ms=self._timeout,
        )

    def p2pname(self, group_name: str) -> P2PNameTarget:
        """
        Return a Target that addresses a group of clients sharing a
        user-supplied P2P name.

        Routing is NOT local-first: even when the caller process itself
        hosts a client in the target group, the call is forwarded to the
        server for dispatch. This preserves the server-side load
        balancing state.

        {!!!!!  RELATION TO SIDE DATA  !!!!!}
        The ``group_name`` passed here is the routing key the CALLER
        uses to address a target group. It is a user-supplied string
        (see ``set_opt_p2p_name`` for how a client declares its own
        group name). This is distinct from the P2P name that a
        RECEIVER reads from a callback's INPUT handle via
        ``DataHandle.get_p2p_name()``: the latter is SIDE DATA
        injected by the SENDER'S transport layer, identifying the
        sender. Both are strings of the same wire type, but they come
        from two different sources and serve two different purposes.

        Args:
            group_name: the P2P group name (UTF-8). This is the value
                        clients set via the runtime option
                        ``LF_P2P_name``.

        Returns:
            A P2PNameTarget sharing this client's connection settings.
        """
        return P2PNameTarget(
            group_name,
            serializer=self._serializer,
            deserializer=self._deserializer,
            default_timeout_ms=self._timeout,
        )

    @property
    def default_target(self) -> AppTarget:
        """
        Return an AppTarget for the default target App name.

        Equivalent to ``self.app(self.default_app_name)``. Provided as
        a convenience so that callers can be explicit about the routing
        mode without having to repeat the app name, e.g.::

            client.default_target.call("api", payload)
            client.default_target.call_async("api", payload)

        The property is a thin factory: each access constructs a fresh
        AppTarget. This is cheap and avoids the pitfalls of caching a
        Target that could outlive a configuration change.
        """
        return self.app(self._app_name)

    # ==================================================================
    # Modern top-level convenience methods
    # ------------------------------------------------------------------
    # These are semantic shortcuts for the corresponding methods on
    # ``self.default_target`` (i.e. an AppTarget for the default app
    # name). They exist so that a caller who is already holding a C4
    # client does not need to spell out the target explicitly for the
    # common case of "call the default app".
    #
    # Both the addressing-mode constructors (``app`` / ``uid`` /
    # ``p2pname``) and these shortcuts share the same underlying
    # connection, serializer, and deserializer.
    # ==================================================================

    def call_future(
        self,
        api_name: str,
        payload: Any = None,
        timeout_ms: Optional[int] = None,
    ) -> CallFuture:
        """
        Send a non-blocking request to the default app.

        This is ``self.default_target.call_future(...)``.

        Returns a :class:`~lingofuse.async_support.CallFuture` that
        resolves with the deserialized result. Never blocks the
        calling thread.

        See :meth:`lingofuse.address.Target.call_future` for the full
        contract (timeout, abandonment, dispatch failure semantics).

        Args:
            api_name:   the remote API name.
            payload:    the payload to send.
            timeout_ms: Python-side timeout in milliseconds. When
                        None, the client's default timeout is used.

        Returns:
            A CallFuture that resolves with the result.
        """
        return self.default_target.call_future(
            api_name, payload, timeout_ms
        )

    async def call_async(
        self,
        api_name: str,
        payload: Any = None,
        timeout_ms: Optional[int] = None,
    ) -> Any:
        """
        Send a non-blocking request to the default app and await the
        result.

        This is ``await self.default_target.call_async(...)``.

        Cancellation of the awaiting task does NOT cancel the
        underlying C request. Use :meth:`call_future` and inspect
        ``future.abandoned`` to distinguish "cancelled" from
        "timed out".

        Args:
            api_name:   the remote API name.
            payload:    the payload to send.
            timeout_ms: Python-side timeout in milliseconds.

        Returns:
            The deserialized result.

        Raises:
            LingoFuseError -- dispatch failed.
            TimeoutError   -- the timeout expired before the callback
                              fired.
        """
        return await self.default_target.call_async(
            api_name, payload, timeout_ms
        )

    def sequenced_call(
        self,
        api_name: str,
        payload: Any = None,
        timeout_ms: Optional[int] = None,
    ) -> Any:
        """
        Send a blocking, FIFO-ordered request to the default app.

        This is ``self.default_target.sequenced_call(...)``. It blocks
        until the response arrives or the timeout expires, and it
        raises on timeout.

        Use :meth:`sequenced_call_future` if you want the non-blocking
        form.

        Args:
            api_name:   the remote API name.
            payload:    the payload to send.
            timeout_ms: Python-side timeout in milliseconds.

        Returns:
            The deserialized result.

        Raises:
            LingoFuseError -- dispatch failed.
            TimeoutError   -- the timeout expired before the callback
                              fired.
        """
        return self.default_target.sequenced_call(
            api_name, payload, timeout_ms
        )

    def sequenced_call_future(
        self,
        api_name: str,
        payload: Any = None,
        timeout_ms: Optional[int] = None,
    ) -> CallFuture:
        """
        Send a non-blocking, FIFO-ordered request to the default app.

        This is ``self.default_target.sequenced_call_future(...)``.
        Ordering is per (app_name, api_name) pair.

        Args:
            api_name:   the remote API name.
            payload:    the payload to send.
            timeout_ms: Python-side timeout in milliseconds.

        Returns:
            A CallFuture that resolves with the result.
        """
        return self.default_target.sequenced_call_future(
            api_name, payload, timeout_ms
        )

    async def sequenced_call_async(
        self,
        api_name: str,
        payload: Any = None,
        timeout_ms: Optional[int] = None,
    ) -> Any:
        """
        Send a non-blocking, FIFO-ordered request to the default app
        and await the result.

        This is ``await self.default_target.sequenced_call_async(...)``.

        Args:
            api_name:   the remote API name.
            payload:    the payload to send.
            timeout_ms: Python-side timeout in milliseconds.

        Returns:
            The deserialized result.

        Raises:
            LingoFuseError -- dispatch failed.
            TimeoutError   -- the timeout expired before the callback
                              fired.
        """
        return await self.default_target.sequenced_call_async(
            api_name, payload, timeout_ms
        )

    # ==================================================================
    # Legacy dynamic-attribute dispatch (unchanged)
    # ==================================================================

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
                # cstr() supplies the NUL-terminated UTF-8 bytes
                # expected by the c_char_p parameter of LF_Call.
                h_res = LF_Call(
                    cstr(self._app_name),
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

    # ==================================================================
    # Legacy explicit methods (unchanged)
    # ==================================================================

    def json_notify(self, api_name: str, data: Any):
        """
        Send a one-way notification with a serialized payload.

        The app name is passed through lingofuse.lf_io.cstr, which
        supplies the NUL-terminated UTF-8 bytes expected by the
        underlying c_char_p parameter of LF_Notify.

        This is a semantic shortcut for::

            client.app(client.default_app_name).notify(api_name, data)

        The two forms are equivalent: both use the same connection, the
        same serializer, and the same wire framing.
        """
        hnd = DataHandle(api_name, data, self._serializer)
        try:
            LF_Notify(cstr(self._app_name), hnd.raw)
        finally:
            hnd.free()

    def json_sequenced_notify(self, api_name: str, data: Any):
        """
        Send a sequenced notification with a serialized payload.

        This guarantees FIFO order for the given (app_name, api_name)
        pair.

        The app name is passed through lingofuse.lf_io.cstr, which
        supplies the NUL-terminated UTF-8 bytes expected by the
        underlying c_char_p parameter of LF_Sequenced_Notify.

        This is a semantic shortcut for::

            client.app(client.default_app_name).sequenced_notify(api_name, data)
        """
        hnd = DataHandle(api_name, data, self._serializer)
        try:
            LF_Sequenced_Notify(cstr(self._app_name), hnd.raw)
        finally:
            hnd.free()

    def json_call(self, api_name: str, data: Any) -> Any:
        """
        Synchronous JSON call: returns deserialized JSON response.

        The app name is passed through lingofuse.lf_io.cstr, which
        supplies the NUL-terminated UTF-8 bytes expected by the
        underlying c_char_p parameter of LF_Call.

        This is a semantic shortcut for::

            client.app(client.default_app_name).call(api_name, data)

        Timeout behaviour: this legacy method preserves its historical
        contract. On timeout, the underlying LF_Call returns an empty
        DataHandle, which this method surfaces as ``None``. The modern
        Target.call method raises TimeoutError instead. Callers that
        rely on the None-on-timeout behaviour should keep using this
        method.
        """
        hnd = DataHandle(api_name, data, self._serializer)
        try:
            h_res = LF_Call(
                cstr(self._app_name),
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
        """Alias for :meth:`json_notify`."""
        return self.json_notify(api_name, data)

    def sequenced_notify(self, api_name: str, data: Any):
        """Alias for :meth:`json_sequenced_notify`."""
        return self.json_sequenced_notify(api_name, data)

    def call(self, api_name: str, data: Any) -> Any:
        """Alias for :meth:`json_call`."""
        return self.json_call(api_name, data)

    # ==================================================================
    # Cleanup (unchanged)
    # ==================================================================

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


# ======================================================================
# Public exports
# ======================================================================

__all__ = ["C4"]