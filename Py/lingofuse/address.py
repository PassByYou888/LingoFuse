# -*- coding: utf-8 -*-
"""
Addressing targets for the LingoFuse Python bindings.

This module implements the three addressing modes that the LingoFuse
C ABI supports for remote invocation:

    * AppTarget      -- address a logical App by its name.
    * UIDTarget      -- address a specific session by its 32-byte UID.
    * P2PNameTarget  -- address a group by its user-supplied P2P name.

All three share a single public surface, defined by the ``Target``
base class. The surface has TWO STYLES, which can be freely mixed:

Legacy style (present since the first release):

    * call(api_name, payload, timeout_ms=...)
        Blocking request/response. Returns the deserialized result.
        Raises TimeoutError on timeout, LingoFuseError on routing
        failure.

    * async_call(api_name, payload, *, on_result, user_data=None)
        Non-blocking request/response with a user-supplied callback.
        Returns 1 if the request was queued successfully, 0 otherwise.
        The ``on_result`` callback fires later on a TCompute worker
        thread.

    * sequenced_call(api_name, payload, timeout_ms=...)
        Blocking request/response with FIFO ordering per
        (target_key, api_name) pair.

    * notify(api_name, payload)
        One-way notification. No response, no ordering guarantee.

    * sequenced_notify(api_name, payload)
        One-way notification with FIFO ordering per
        (target_key, api_name) pair.

Modern style (introduced with the async_support subsystem):

    * call_future(api_name, payload, timeout_ms=...)
        Non-blocking request/response. Returns a
        :class:`~lingofuse.async_support.CallFuture` that resolves
        with the deserialized result. Never blocks.

    * call_async(api_name, payload, timeout_ms=...)
        ``async def`` coroutine. Awaits a ``CallFuture`` and returns
        the result. Suitable for use with asyncio.

    * sequenced_call_future(api_name, payload, timeout_ms=...)
        Non-blocking, FIFO-ordered request/response. Returns a
        ``CallFuture``.

    * sequenced_call_async(api_name, payload, timeout_ms=...)
        ``async def`` coroutine for the FIFO-ordered variant.

The modern style is the recommended path for new code. It is built
on the :mod:`lingofuse.async_support` subsystem, which manages the
lifetime of every ctypes callback object safely: timeouts do not
cause use-after-free, dispatch failures do not leak, and callers
can distinguish "cancelled" from "timed out" via
``CallFuture.abandoned``.

The legacy style remains fully supported. It is implemented on top
of the same subsystem internally; the observable behaviour is
unchanged.

=========================== ADDRESSING SEMANTICS ===========================
The three addressing modes share the same call syntax but differ in
routing semantics:

+------------------+----------------+--------------+------------------+
| Mode             | Routing key    | Local-first? | Load-balanced?   |
+==================+================+==============+==================+
| AppTarget        | App name (str) | YES          | N/A              |
| UIDTarget        | UID (32 bytes) | YES          | N/A              |
| P2PNameTarget    | Group name     | NO           | YES (server side)|
+------------------+----------------+--------------+------------------+

Local-first means: if the caller process itself hosts a matching App /
client for the addressing key, the call is serviced locally without
touching the network. P2PName deliberately opts out of local-first
routing: the server-side dispatcher owns the load-balancing state, and
short-cutting locally would defeat it.

=========================== UID LIFECYCLE ==================================
A UID is a session identifier generated during TunnelLink. It is
regenerated on every reconnect: callers that cache a UID MUST re-probe
it after a link loss.

{!!!!!  HOW TO OBTAIN A UID (SIDE DATA SEMANTICS)  !!!!!}
The UID is NOT a property of any handle the caller creates. It is
SIDE DATA that the SENDER'S transport layer injects automatically
into every request payload before transmission (Pascal side:
TC40_LF_Client.Send_* -> TMemory_Param_Tool.Rebuild_UID_and_P2PName).
The receiver side therefore sees the sender's UID in the Data_Param
of the INPUT handle it receives from the framework.

The canonical way to learn a client's own UID is the "whoami"
pattern: register a Call API on the target side whose callback
reads the caller's UID from its INPUT handle:

    from lingofuse.core import DataHandle

    @server.expose("whoami")
    def whoami(trigger, inp: DataHandle, out: DataHandle):
        # inp is an INPUT handle carrying the sender's side data.
        # get_p2p_uid() returns a fresh 32-byte bytes object.
        caller_uid = inp.get_p2p_uid()
        out.write_bytes(caller_uid)

The client then calls ``whoami`` and caches the returned UID. When
the link is re-established, the client MUST re-probe, because the
UID is regenerated on every TunnelLink.

The reverse direction (a caller constructing a UIDTarget to address
a remote client) uses the same 32-byte value:

    target = UIDTarget(caller_uid)
    target.call("some_api", payload)

See :class:`lingofuse.core.DataHandle` for the full side-data
contract of ``get_p2p_uid`` / ``get_p2p_name``.

=========================== ASYNC CALLBACK CONTRACT ========================
Every asynchronous callback in this module runs on a TCompute worker
thread (NOT the calling thread and NOT the simulated main thread).
The callback MUST NOT block, and MUST NOT call any synchronous
LingoFuse function (LF_Call / LF_Notify / LF_LocalCall / LF_PrepareDone
/ LF_Shutdown): doing so will deadlock.

The legacy ``on_result`` handler passed to ``async_call`` has the
signature::

    def on_result(result: Any, error: Optional[Exception], user_data: Any) -> None:
        ...

The ``error`` argument is either an exception instance (deserialization
or internal failure) or ``None``. The ``result`` argument is the
deserialized payload, or ``None`` when the payload was empty.

Exceptions raised inside the handler are logged and swallowed. They are
NOT propagated to the C stack, and they do NOT affect the framework's
state.

=========================== CALLBACK LIFETIME ==============================
The C library holds a raw function pointer to each installed async
callback. If the corresponding ctypes callback object is garbage
collected while the pointer is still live, the next invocation will
crash.

This module delegates that lifetime management entirely to
:class:`lingofuse.async_support.AsyncBridge`. Every callback object is
wrapped in an :class:`~lingofuse.async_support.AsyncOp` that owns a
strong reference to it and is registered with the bridge BEFORE the
pointer is handed to the C library. The bridge releases the reference
only after the op's state machine permits:

    * callback fired (state FIRED), or
    * dispatch failed (state NOT_QUEUED), or
    * timeout fired + grace period elapsed (state ABANDONED).

This is what makes the modern API safe under timeouts and dispatch
failures. It is also why the legacy API no longer leaks or corrupts
memory on those paths.

=========================== PAYLOAD SERIALIZATION ==========================
Payloads are serialized and deserialized via the ``serializer`` /
``deserializer`` callables passed to the ``Target`` constructor. In
normal use these are inherited from the owning ``C4`` client, whose
defaults come from ``lingofuse.serializers``. The serializer MUST
produce bytes; the deserializer MUST accept bytes. See
``lingofuse/serializers.py`` for the default implementation.

The wire payload is written to a ``DataHandle`` at position 0 and read
back from position 0. This matches the existing behavior of the
``C4`` dynamic-attribute path and preserves binary compatibility with
peers built against earlier versions of the bindings.

=========================== THREAD SAFETY ==================================
``Target`` instances are immutable after construction and are safe to
share across threads. However, a single ``Target`` instance does NOT
serialize concurrent calls: two threads calling ``target.call(...)``
simultaneously will issue two independent requests. The underlying C
library serializes them internally per connection.

The modern ``call_future`` / ``call_async`` methods are safe to call
concurrently from any thread and from any asyncio task. The returned
``CallFuture`` is a standard ``concurrent.futures.Future`` and follows
its thread-safety contract.
"""

from __future__ import annotations

import concurrent.futures
import logging
import threading
from typing import Any, Callable, Optional

from ._lf_native import (
    DataHnd,
    LF_Call,
    LF_Async_Call,
    LF_Async_Sequenced_Call,
    LF_Notify,
    LF_Sequenced_Notify,
    LF_UID_Call,
    LF_UID_Async_Call,
    LF_UID_Async_Sequenced_Call,
    LF_UID_Notify,
    LF_UID_Sequenced_Notify,
    LF_P2PNAME_Call,
    LF_P2PNAME_Async_Call,
    LF_P2PNAME_Async_Sequenced_Call,
    LF_P2PNAME_Notify,
    LF_P2PNAME_Sequenced_Notify,
    LF_FreeData,
    LF_GetSize,
    TP2P_UID,
)
from .async_support import (
    CallFuture,
    await_future,
    make_legacy_op,
    run_async_with_future,
)
from .core import DataHandle
from .errors import LingoFuseError, TimeoutError
from .lf_io import cstr
from .serializers import default_serializer, default_deserializer


_log = logging.getLogger("lingofuse.address")


# ======================================================================
# Public type alias
# ======================================================================

#: Signature of the user-supplied async result handler.
#:
#: Parameters:
#:     result     -- the deserialized payload, or None if empty.
#:     error      -- an Exception instance, or None on success.
#:     user_data  -- the opaque value the caller passed to async_call.
AsyncResultHandler = Callable[[Any, Optional[Exception], Any], None]


# ======================================================================
# UID normalization helpers
# ======================================================================
#
# {!!!!!  THE UID AS AN ARGUMENT IS A VALUE, NOT SIDE DATA  !!!!!}
# The functions below take a Python-level UID value (bytes / hex
# string) and prepare it for use as an ARGUMENT to one of the
# LF_UID_* call primitives. The C ABI represents such an argument as
# a 32-byte array (Pascal: TP2P_UID___ = array[0..31] of Byte), and
# ctypes passes arrays by value in a cdecl call. The ctypes type used
# here is therefore ``TP2P_UID`` (a ``c_ubyte * 32`` array).
#
# This is a DIFFERENT role from the LF_Get_P2P_UID RETURN value, which
# is a POINTER to a 32-byte UID (Pascal: PP2P_UID___ = ^TUID___).
# See ``lingofuse._lf_native`` and ``lingofuse.core.DataHandle`` for
# the return-role contract. The two roles use different ctypes
# representations and must not be conflated.
# ======================================================================

def _normalize_uid(uid) -> bytes:
    """
    Normalize a UID value into a 32-byte ``bytes`` object.

    Accepted inputs:
        * bytes / bytearray / memoryview with length exactly 32
        * a 64-character hexadecimal string

    Raises:
        ValueError  -- if the length is wrong or the hex string is
                       malformed.
        TypeError   -- if the type is not one of the accepted forms.
    """
    if isinstance(uid, bytes):
        if len(uid) != 32:
            raise ValueError(
                f"UID must be exactly 32 bytes, got {len(uid)}"
            )
        return uid
    if isinstance(uid, (bytearray, memoryview)):
        b = bytes(uid)
        if len(b) != 32:
            raise ValueError(
                f"UID must be exactly 32 bytes, got {len(b)}"
            )
        return b
    if isinstance(uid, str):
        try:
            b = bytes.fromhex(uid)
        except ValueError as exc:
            raise ValueError(
                f"UID hex string is malformed: {uid!r}"
            ) from exc
        if len(b) != 32:
            raise ValueError(
                f"UID hex string must be 64 hex characters, "
                f"got {len(uid)}"
            )
        return b
    raise TypeError(
        f"UID must be bytes / bytearray / memoryview / 64-char hex str, "
        f"got {type(uid).__name__}"
    )


def _to_tp2p_uid(uid_bytes: bytes) -> Any:
    """
    Convert a 32-byte ``bytes`` object into a ``TP2P_UID`` array.

    ``TP2P_UID`` is ``ctypes.c_ubyte * 32``. The conversion is a
    straight element-wise copy; no reinterpretation is performed.

    This produces an ARGUMENT-role value suitable for the first
    parameter of ``LF_UID_Call`` and its siblings. The C ABI declares
    that parameter as ``TP2P_UID___`` (a 32-byte Pascal array), which
    ctypes passes by value in a cdecl call.

    The return type is annotated as ``Any`` because ``TP2P_UID`` is
    a runtime object produced by ``ctypes`` (a fixed-size array
    type), not a static type. Static analysers such as Pylance
    reject it in a type-expression position with
    ``reportInvalidTypeForm``. The runtime behaviour is identical.
    """
    arr = TP2P_UID()
    for i, b in enumerate(uid_bytes):
        arr[i] = b
    return arr


# ======================================================================
# Target base class
# ======================================================================

class Target:
    """
    Abstract base class for the three addressing modes.

    Concrete subclasses implement the five ``_raw_*`` hooks (one per
    underlying C ABI function family). The public API -- both the
    legacy style and the modern style -- is defined once here and
    shared by all addressing modes, so the addressing semantics remain
    orthogonal to the call-shape semantics.

    Instances are immutable after construction. The three concrete
    subclasses (``AppTarget`` / ``UIDTarget`` / ``P2PNameTarget``)
    are the ONLY supported ways to construct a Target; the base class
    should not be instantiated directly.
    """

    __slots__ = ("_serializer", "_deserializer", "_default_timeout_ms")

    def __init__(self, *, serializer, deserializer, default_timeout_ms):
        self._serializer = serializer
        self._deserializer = deserializer
        self._default_timeout_ms = default_timeout_ms

    # ------------------------------------------------------------------
    # Subclass hooks (private)
    # ------------------------------------------------------------------
    # Each hook wraps exactly one family of C ABI functions. The base
    # class provides no implementation: a subclass that forgets one
    # hook will fail loudly with NotImplementedError at call time.

    def _raw_call(self, api_name: str, hnd: DataHnd, timeout_ms: int) -> DataHnd:
        """Invoke the synchronous Call primitive for this addressing mode."""
        raise NotImplementedError

    def _raw_async_call(self, api_name: str, hnd: DataHnd, callback) -> int:
        """Invoke the asynchronous Call primitive for this addressing mode."""
        raise NotImplementedError

    def _raw_async_sequenced_call(
        self, api_name: str, hnd: DataHnd, callback
    ) -> int:
        """Invoke the asynchronous sequenced Call primitive."""
        raise NotImplementedError

    def _raw_notify(self, api_name: str, hnd: DataHnd) -> None:
        """Invoke the one-way Notify primitive for this addressing mode."""
        raise NotImplementedError

    def _raw_sequenced_notify(self, api_name: str, hnd: DataHnd) -> None:
        """Invoke the one-way sequenced Notify primitive."""
        raise NotImplementedError

    # ------------------------------------------------------------------
    # Diagnostic hook
    # ------------------------------------------------------------------

    def _describe(self) -> str:
        """
        Return a short human-readable description of this target, used
        in exception messages and log lines. Subclasses override this
        to include the addressing key.
        """
        return repr(self)

    # ------------------------------------------------------------------
    # Result deserialization
    # ------------------------------------------------------------------

    def _deserialize_result(self, raw_result) -> Any:
        """
        Convert a raw result handle into a Python object.

        Called from the C worker thread (inside an async callback) or
        from the caller thread (inside a synchronous call). The raw
        handle is owned by the framework; we wrap it with
        ``owned=False`` and never call ``free()`` on it.

        Returns ``None`` for an empty handle. Raises any exception
        the deserializer raises; the async machinery converts that
        into an ``error`` delivered to the caller's callback or
        resolved onto the Future.
        """
        if not raw_result:
            return None
        result_hnd = DataHandle._from_raw(raw_result, owned=False)
        return result_hnd.read(self._deserializer)

    # ==================================================================
    # Legacy public API
    # ==================================================================

    def call(self, api_name, payload=None, timeout_ms=None):
        """
        Send a blocking request and return the deserialized result.

        Args:
            api_name:   the remote API name (UTF-8).
            payload:    any Python object the serializer accepts; the
                        default serializer (from ``serializers``) is
                        JSON-compatible.
            timeout_ms: timeout in milliseconds. When None, the target's
                        default timeout is used.

        Returns:
            The deserialized result. ``None`` if the peer returned an
            empty payload.

        Raises:
            LingoFuseError -- the library could not allocate a result
                              handle, or the underlying call reported a
                              transport-level failure.
            TimeoutError   -- the call did not complete within the
                              timeout window. Note that the underlying
                              library returns an empty handle on
                              timeout rather than raising; we detect
                              this by inspecting the result size.
        """
        if timeout_ms is None:
            timeout_ms = self._default_timeout_ms

        data = DataHandle(api_name, payload, self._serializer)
        try:
            h_res = self._raw_call(api_name, data.raw, timeout_ms)
        finally:
            data.free()

        if not h_res:
            raise LingoFuseError(
                f"Call to {api_name!r} on {self._describe()} "
                f"returned a null handle"
            )

        # A non-null handle with size 0 means the call timed out. The
        # library has already created the handle, so we must release it
        # before raising.
        if LF_GetSize(h_res) == 0:
            LF_FreeData(h_res)
            raise TimeoutError(
                f"Call to {api_name!r} on {self._describe()} "
                f"timed out after {timeout_ms}ms"
            )

        # Success path: wrap the handle as an owned DataHandle so that
        # the result is released deterministically.
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

    def async_call(
        self,
        api_name,
        payload=None,
        *,
        on_result: AsyncResultHandler,
        user_data: Any = None,
    ) -> int:
        """
        Send a non-blocking request with a user-supplied callback.

        The callback fires on a TCompute worker thread once the
        response arrives. It receives ``(result, error, user_data)``
        as described in the module docstring.

        Returns:
            1 if the request was queued successfully, 0 otherwise.
            A return value of 0 means the callback will never fire
            (the op is released immediately to avoid a leak).

        Raises:
            ValueError -- ``on_result`` is None.
        """
        if on_result is None:
            raise ValueError(
                "on_result callback is required for async_call"
            )

        data = DataHandle(api_name, payload, self._serializer)
        try:
            op = make_legacy_op(
                on_result=on_result,
                user_data=user_data,
                deserialize=self._deserialize_result,
            )
            ret = self._raw_async_call(api_name, data.raw, op.c_callback)
            if ret != 1:
                # Dispatch failed; the callback will never fire.
                # Release the op explicitly to avoid a keepalive leak.
                op.mark_not_queued()
            return ret
        finally:
            data.free()

    def sequenced_call(self, api_name, payload=None, timeout_ms=None):
        """
        Send a blocking request with FIFO ordering per
        (target_key, api_name) pair.

        This method is a thin wrapper around
        :meth:`sequenced_call_future`: it issues the request, then
        blocks on the returned Future. The FIFO guarantee and the
        timeout are both enforced by the underlying subsystem.

        Args:
            api_name:   the remote API name.
            payload:    the payload to send.
            timeout_ms: timeout in milliseconds.

        Returns:
            The deserialized result.

        Raises:
            LingoFuseError -- the request was rejected before dispatch,
                              or the library could not allocate a
                              result handle.
            TimeoutError   -- the call did not complete within the
                              timeout window. The C request may still
                              be in flight; its result will be
                              discarded.
        """
        future = self.sequenced_call_future(api_name, payload, timeout_ms)
        # The bridge resolves the Future on success, timeout, or
        # dispatch failure. Block until it does. No additional timeout
        # is applied here: the Future already carries the correct
        # exception, and adding a second timeout would only obscure it.
        return future.result()

    def notify(self, api_name, payload=None) -> None:
        """
        Send a one-way notification. Returns immediately.

        No response is expected, and no ordering guarantee is provided.
        Use ``sequenced_notify`` when ordering matters.
        """
        data = DataHandle(api_name, payload, self._serializer)
        try:
            self._raw_notify(api_name, data.raw)
        finally:
            data.free()

    def sequenced_notify(self, api_name, payload=None) -> None:
        """
        Send a one-way notification with FIFO ordering per
        (target_key, api_name) pair. Returns immediately.
        """
        data = DataHandle(api_name, payload, self._serializer)
        try:
            self._raw_sequenced_notify(api_name, data.raw)
        finally:
            data.free()

    # ==================================================================
    # Modern public API (Future / asyncio)
    # ==================================================================

    def call_future(
        self,
        api_name,
        payload=None,
        timeout_ms=None,
    ) -> CallFuture:
        """
        Send a non-blocking request. Returns a ``CallFuture``.

        The Future resolves with the deserialized result once the
        response arrives. It never blocks the calling thread.

        Timeout and abandonment
        -----------------------
        If ``timeout_ms`` is provided and the callback does not fire
        within that window, the Future is resolved with
        :class:`~lingofuse.errors.TimeoutError` and its
        ``abandoned`` flag becomes True. The C request is NOT
        cancelled; it may still complete, and its result will be
        silently discarded.

        Dispatch failure
        ----------------
        If the library rejects the request before dispatching it, the
        Future is resolved with :class:`~lingofuse.errors.LingoFuseError`.
        No leak occurs in this case.

        Thread safety
        -------------
        Safe to call from any thread. The returned Future is a
        standard ``concurrent.futures.Future``.

        Args:
            api_name:   the remote API name.
            payload:    the payload to send.
            timeout_ms: Python-side timeout in milliseconds. When
                        None, the target's default timeout is used.

        Returns:
            A ``CallFuture`` that resolves with the result.
        """
        if timeout_ms is None:
            timeout_ms = self._default_timeout_ms

        data = DataHandle(api_name, payload, self._serializer)
        try:
            # run_async_with_future handles op creation, registration,
            # dispatch, and timeout arming. If dispatch fails, the
            # Future is resolved with a LingoFuseError and the op is
            # released (state NOT_QUEUED).
            return run_async_with_future(
                issue_fn=lambda cb: self._raw_async_call(
                    api_name, data.raw, cb
                ),
                deserialize=self._deserialize_result,
                timeout_ms=timeout_ms,
            )
        finally:
            # The C ABI encodes the payload synchronously inside
            # _raw_async_call, so the DataHandle is no longer needed
            # by the time we get here. Freeing it releases the
            # underlying record to the pool.
            data.free()

    async def call_async(
        self,
        api_name,
        payload=None,
        timeout_ms=None,
    ) -> Any:
        """
        Send a non-blocking request and await the result.

        This is the asyncio-friendly wrapper around
        :meth:`call_future`. It returns the deserialized result
        directly.

        Cancellation
        ------------
        Cancelling the awaiting task does NOT cancel the underlying C
        request. The request may still complete, and its result will
        be discarded. To distinguish "cancelled" from "timed out",
        use :meth:`call_future` and inspect ``future.abandoned``.

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
        future = self.call_future(api_name, payload, timeout_ms)
        return await await_future(future)

    def sequenced_call_future(
        self,
        api_name,
        payload=None,
        timeout_ms=None,
    ) -> CallFuture:
        """
        Send a non-blocking request with FIFO ordering per
        (target_key, api_name) pair. Returns a ``CallFuture``.

        Semantics are identical to :meth:`call_future`, except that
        the framework maintains a dedicated dispatch thread per
        (target_key, api_name) so requests are delivered in the order
        they were issued. Concurrency across different keys is
        preserved.

        Args:
            api_name:   the remote API name.
            payload:    the payload to send.
            timeout_ms: Python-side timeout in milliseconds.

        Returns:
            A ``CallFuture`` that resolves with the result.
        """
        if timeout_ms is None:
            timeout_ms = self._default_timeout_ms

        data = DataHandle(api_name, payload, self._serializer)
        try:
            return run_async_with_future(
                issue_fn=lambda cb: self._raw_async_sequenced_call(
                    api_name, data.raw, cb
                ),
                deserialize=self._deserialize_result,
                timeout_ms=timeout_ms,
            )
        finally:
            data.free()

    async def sequenced_call_async(
        self,
        api_name,
        payload=None,
        timeout_ms=None,
    ) -> Any:
        """
        Send a non-blocking, FIFO-ordered request and await the result.

        This is the asyncio-friendly wrapper around
        :meth:`sequenced_call_future`.

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
        future = self.sequenced_call_future(api_name, payload, timeout_ms)
        return await await_future(future)


# ======================================================================
# App-name addressing
# ======================================================================

class AppTarget(Target):
    """
    Address a logical App by its name.

    Routing is LOCAL-FIRST: if the caller process itself hosts an App
    with the matching name and the requested API, the call is serviced
    locally without touching the network.
    """

    __slots__ = ("_app_name",)

    def __init__(
        self,
        app_name: str,
        *,
        serializer=default_serializer,
        deserializer=default_deserializer,
        default_timeout_ms: int = 5000,
    ):
        super().__init__(
            serializer=serializer,
            deserializer=deserializer,
            default_timeout_ms=default_timeout_ms,
        )
        self._app_name = app_name

    @property
    def app_name(self) -> str:
        """The App name this target addresses."""
        return self._app_name

    def _describe(self) -> str:
        return f"app({self._app_name!r})"

    def _raw_call(self, api_name, hnd, timeout_ms):
        return LF_Call(cstr(self._app_name), hnd, timeout_ms)

    def _raw_async_call(self, api_name, hnd, callback):
        return LF_Async_Call(cstr(self._app_name), hnd, None, callback)

    def _raw_async_sequenced_call(self, api_name, hnd, callback):
        return LF_Async_Sequenced_Call(
            cstr(self._app_name), hnd, None, callback
        )

    def _raw_notify(self, api_name, hnd):
        LF_Notify(cstr(self._app_name), hnd)

    def _raw_sequenced_notify(self, api_name, hnd):
        LF_Sequenced_Notify(cstr(self._app_name), hnd)

    def __repr__(self) -> str:
        return f"AppTarget(app_name={self._app_name!r})"

    def __eq__(self, other) -> bool:
        if not isinstance(other, AppTarget):
            return NotImplemented
        return self._app_name == other._app_name

    def __hash__(self) -> int:
        return hash(("AppTarget", self._app_name))


# ======================================================================
# UID addressing
# ======================================================================

class UIDTarget(Target):
    """
    Address a specific session by its 32-byte UID.

    Routing is LOCAL-FIRST, matching AppTarget. The UID is regenerated
    on every TunnelLink, so callers that cache a UID must re-probe it
    after a link loss.

    The ``uid`` argument may be:
        * bytes / bytearray / memoryview of length exactly 32
        * a 64-character hexadecimal string

    The UID can address any API registered on the target -- whether
    app-bound (via ``App.register_call``) or process-wide (via
    ``lingofuse.register_p2p_call``) -- without requiring the caller to
    know the target App name.

    {!!!!!  HOW TO OBTAIN THE UID  !!!!!}
    The UID is SIDE DATA injected by the sender's transport layer, not
    a property of any handle the caller creates. To learn a client's
    own UID, use the "whoami" pattern: register a Call API on the
    target side that reads the caller's UID from its INPUT handle via
    ``DataHandle.get_p2p_uid()``, and call it from the client. See the
    module docstring section "UID LIFECYCLE" for the full pattern.
    """

    __slots__ = ("_uid_bytes", "_uid_for_c")

    def __init__(
        self,
        uid,
        *,
        serializer=default_serializer,
        deserializer=default_deserializer,
        default_timeout_ms: int = 5000,
    ):
        super().__init__(
            serializer=serializer,
            deserializer=deserializer,
            default_timeout_ms=default_timeout_ms,
        )
        self._uid_bytes = _normalize_uid(uid)
        self._uid_for_c = _to_tp2p_uid(self._uid_bytes)

    @property
    def uid_bytes(self) -> bytes:
        """The 32-byte UID as a Python ``bytes`` object."""
        return self._uid_bytes

    def _describe(self) -> str:
        return f"uid({self._uid_bytes.hex()})"

    def _raw_call(self, api_name, hnd, timeout_ms):
        return LF_UID_Call(self._uid_for_c, hnd, timeout_ms)

    def _raw_async_call(self, api_name, hnd, callback):
        return LF_UID_Async_Call(self._uid_for_c, hnd, None, callback)

    def _raw_async_sequenced_call(self, api_name, hnd, callback):
        return LF_UID_Async_Sequenced_Call(
            self._uid_for_c, hnd, None, callback
        )

    def _raw_notify(self, api_name, hnd):
        LF_UID_Notify(self._uid_for_c, hnd)

    def _raw_sequenced_notify(self, api_name, hnd):
        LF_UID_Sequenced_Notify(self._uid_for_c, hnd)

    def __repr__(self) -> str:
        return f"UIDTarget(uid={self._uid_bytes.hex()})"

    def __eq__(self, other) -> bool:
        if not isinstance(other, UIDTarget):
            return NotImplemented
        return self._uid_bytes == other._uid_bytes

    def __hash__(self) -> int:
        return hash(("UIDTarget", self._uid_bytes))


# ======================================================================
# P2PName addressing
# ======================================================================

class P2PNameTarget(Target):
    """
    Address a group of clients by their shared P2P name.

    Routing is NOT local-first. Even when the caller process itself
    hosts a client in the target group, the call is forwarded to the
    server for dispatch. This is a deliberate design choice: the
    server-side dispatcher owns the load-balancing state, and
    short-cutting locally would defeat it.

    The server-side dispatcher picks a target using one of two
    strategies:

        * Load balancing (Cycle_Anchor): the target with the smallest
          anchor value is chosen, and its anchor is then advanced.

        * Sticky affinity (FixedSequenced, governed by the runtime
          option ``Fixed_Sequenced_Time``, default 20 seconds): the
          same target is kept for a bounded period.

    The group name is the value a client sets via the runtime option
    ``LF_P2P_name``. Multiple clients can share a group name; the
    server dispatches calls among them.

    {!!!!!  RELATION TO SIDE DATA  !!!!!}
    The P2P name that the CALLER uses to address a target group is a
    user-supplied string (see ``set_opt_p2p_name``). This is distinct
    from the P2P name that a RECEIVER reads from a callback's INPUT
    handle via ``DataHandle.get_p2p_name()``: the latter is SIDE DATA
    injected by the SENDER'S transport layer, identifying the sender.
    Both are 32-byte-agnostic strings, but they serve different
    purposes and are obtained through different mechanisms.
    """

    __slots__ = ("_group_name",)

    def __init__(
        self,
        group_name: str,
        *,
        serializer=default_serializer,
        deserializer=default_deserializer,
        default_timeout_ms: int = 5000,
    ):
        super().__init__(
            serializer=serializer,
            deserializer=deserializer,
            default_timeout_ms=default_timeout_ms,
        )
        self._group_name = group_name

    @property
    def group_name(self) -> str:
        """The P2P group name this target addresses."""
        return self._group_name

    def _describe(self) -> str:
        return f"p2pname({self._group_name!r})"

    def _raw_call(self, api_name, hnd, timeout_ms):
        return LF_P2PNAME_Call(cstr(self._group_name), hnd, timeout_ms)

    def _raw_async_call(self, api_name, hnd, callback):
        return LF_P2PNAME_Async_Call(
            cstr(self._group_name), hnd, None, callback
        )

    def _raw_async_sequenced_call(self, api_name, hnd, callback):
        return LF_P2PNAME_Async_Sequenced_Call(
            cstr(self._group_name), hnd, None, callback
        )

    def _raw_notify(self, api_name, hnd):
        LF_P2PNAME_Notify(cstr(self._group_name), hnd)

    def _raw_sequenced_notify(self, api_name, hnd):
        LF_P2PNAME_Sequenced_Notify(cstr(self._group_name), hnd)

    def __repr__(self) -> str:
        return f"P2PNameTarget(group_name={self._group_name!r})"

    def __eq__(self, other) -> bool:
        if not isinstance(other, P2PNameTarget):
            return NotImplemented
        return self._group_name == other._group_name

    def __hash__(self) -> int:
        return hash(("P2PNameTarget", self._group_name))


# ======================================================================
# Public exports
# ======================================================================

__all__ = [
    "Target",
    "AppTarget",
    "UIDTarget",
    "P2PNameTarget",
    "AsyncResultHandler",
]