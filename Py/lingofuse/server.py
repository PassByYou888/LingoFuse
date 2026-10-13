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

{!!!!!  BYTES ROUND-TRIP FIX  !!!!!}
Earlier revisions of this module defined both
``_convert_to_serializable`` and ``_convert_from_serializable`` but
only used the former. As a result, a Python ``bytes`` argument sent
to a Server API was serialized as ``{"__bytes__": <base64>}`` on the
way in, but arrived at the user function as that dict, not as
``bytes`` again. The read path now applies
``_convert_from_serializable`` unconditionally, so the round-trip is
symmetric:

    user sends   bytes               -> wire: {"__bytes__": <b64>}
    user fn sees bytes               -> wire: {"__bytes__": <b64>}
    user returns bytes               -> wire: {"__bytes__": <b64>}
    caller sees  bytes               -> wire: {"__bytes__": <b64>}

This matches the documented ``__bytes__`` convention. Callers who
need to carry a literal dict of that exact shape must wrap it one
level deeper (e.g., ``{"data": {"__bytes__": "..."}}``) so that it
is not confused with the convention.

{!!!!!  STRING PARAMETERS  !!!!!}
Every string argument passed to an LF_* function from this module is
routed through `lingofuse.lf_io.cstr`, which supplies NUL-terminated
UTF-8 bytes for the c_char_p parameter. This removes the previous
reliance on the hidden NUL byte inside CPython bytes objects and
makes the wire contract explicit.

{!!!!!  TWO REGISTRATION NAMESPACES  !!!!!}
As of the current revision, `Server.expose()` supports TWO independent
registration namespaces, selected by the `p2p` flag:

    # App-bound registration (default; historical behaviour):
    @server.expose("add")
    def add(a, b): ...

    # Process-wide P2P registration:
    @server.expose("whoami", p2p=True)
    def whoami(): ...

The two namespaces are ORTHOGONAL:

    App-bound namespace:
        - Owned by the Server's App.
        - Reachable via App-name addressing (`client.app("X").call(...)`)
          and via UID addressing.
        - Dies with the App (which is detached by `LF_FreeApp` and
          destroyed by `LF_Shutdown`).

    Process-wide P2P namespace:
        - Owned by the process, NOT by the Server's App.
        - Reachable via UID addressing and P2PName addressing ONLY.
        - NOT reachable via App-name addressing, even if the registered
          API name happens to match an App name.
        - Survives until the process exits, regardless of whether the
          Server's App has been freed.

The dispatch shape (how the incoming JSON payload is turned into the
user function's arguments) is IDENTICAL for both namespaces. Only the
routing key differs. See `Server.expose` for the full contract.

{!!!!!  WHAT `p2p=True` DOES NOT DO  !!!!!}
- It does NOT require the Server's App to be alive. If you want to
  register ONLY process-wide P2P APIs, you may still construct a
  Server (its App is created automatically and used only for the
  app-bound namespace); the App is simply unused.
- It does NOT bypass the Server's lifecycle. `Server.stop()` stops
  the network loop and frees the App, but process-wide P2P APIs
  registered through this Server remain registered in the library
  until `LF_Shutdown()` is called.

{!!!!!  AUTO SENDER IDENTITY (SIDE DATA)  !!!!!}
Every inbound request payload carries two identity fields that the
SENDER'S transport layer injects automatically before transmission
(Pascal side: TC40_LF_Client.Send_* ->
TMemory_Param_Tool.Rebuild_UID_and_P2PName):

    * FromUID      -- the sender's 32-byte session UID.
    * FromP2PName  -- the sender's user-supplied P2P group name.

These two fields are "SIDE DATA". They are NOT properties of the
handle itself. They are metadata that the sender wrote into the
payload header, and the receiver therefore sees them in the
Data_Param of the INPUT handle it receives from the framework.

Inside a Server callback, the user function receives the INPUT handle
as a DataHandle (see `_make_call_adapter` / `_make_notify_adapter`).
That handle exposes two side-data accessors:

    inp.get_p2p_uid()   -> bytes (exactly 32 bytes)
    inp.get_p2p_name()  -> str   ('' if the sender did not set a name)

These accessors work ONLY on INPUT handles. Calling them on a handle
the caller created itself, or on an output handle, yields a null UID
/ empty string.

{!!!!!  THE whoami PATTERN  !!!!!}
The canonical use of side data is the "whoami" probe: a client calls
a registered API to learn its OWN UID (which the server sees as the
sender's UID). Example:

    from lingofuse.core import DataHandle

    @server.expose("whoami")
    def whoami(trigger, inp: DataHandle, out: DataHandle):
        # inp is the INPUT handle carrying the sender's side data.
        # get_p2p_uid() returns a fresh 32-byte bytes object.
        caller_uid = inp.get_p2p_uid()
        caller_name = inp.get_p2p_name()
        out.write_json({
            "uid_hex": caller_uid.hex(),
            "p2p_name": caller_name,
        })

A client then calls ``whoami`` and caches the returned UID. Because
the UID is regenerated on every TunnelLink, the client must re-probe
after a link loss. See ``lingofuse.core.DataHandle.get_p2p_uid`` for
the full side-data contract.

Note: an adapter that wraps the raw ctypes handles (as this module's
``_make_call_adapter`` does) must pass the INPUT handle through as a
DataHandle so that the user function can call ``get_p2p_uid`` /
``get_p2p_name`` on it. The adapters in this module already do so.
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
# lf_io in a previous revision. No additional import is needed for
# that path.
from .lf_io import cstr


# ======================================================================
# Internal serialization helpers
# ----------------------------------------------------------------------
# These helpers recursively convert between Python objects and JSON
# shapes that can carry raw bytes. They are used by the `expose`
# decorator and by the json_* methods.
#
# The two functions are DESIGNED TO BE SYMMETRIC:
#
#     _convert_to_serializable   bytes -> {"__bytes__": b64}
#     _convert_from_serializable {"__bytes__": b64} -> bytes
#
# Both directions recurse through lists and dicts. See the module
# docstring section "BYTES ROUND-TRIP FIX" for the exact contract.
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
    """
    Recursively convert a dict containing __bytes__ back to bytes.

    A dict is treated as the ``__bytes__`` convention only when it has
    EXACTLY ONE key, and that key is literally ``"__bytes__"``. A dict
    with additional keys is treated as a normal dict and recursed into.
    This rule is identical on the encode side (``_convert_to_serializable``
    emits exactly that shape), so the two directions round-trip
    correctly for every JSON-representable value.

    The base64 decoding is wrapped in a try/except so that a
    malformed payload (for example, a peer that sent
    ``{"__bytes__": "not-base64!"}``) does not crash the callback.
    In that case the original dict is returned unchanged.
    """
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
    Read JSON from a DataHandle and restore any base64-encoded bytes.

    The write path (``_write_json``) transforms Python ``bytes``
    objects into ``{"__bytes__": <base64>}`` dicts so that they can
    survive a JSON round-trip. This function reverses that
    transformation, recursively, so that bytes parameters arrive at
    the user function as ``bytes`` again instead of as a dict.

    {!!!!!  STRICT JSON READING  !!!!!}
    This function uses ``DataHandle.read_json_strict()`` rather than
    the lenient ``read_json()``. The reason is that the Server's
    argument-dispatch rules interpret ``None`` as "call the user
    function with no arguments". Under the lenient behaviour, a
    malformed payload would be silently turned into ``None`` and the
    user function would be invoked without arguments, which is
    almost never what the caller intended.

    With strict reading:

      * An empty payload still returns ``None`` (no-argument call).
      * A malformed payload raises ``RuntimeError``, which is caught
        by the surrounding adapter. In Call mode the exception is
        converted into a structured ``{"__error__": ...}`` response;
        in Notify mode it is logged and the notification is dropped.

    This makes protocol errors visible at the caller instead of
    being silently masked as a "no-argument" dispatch.

    The transformation is applied unconditionally on the read side.
    A user dict that happens to contain a single key ``"__bytes__"``
    whose value is a valid base64 string will be converted back to
    ``bytes``. This is the documented behaviour of the
    ``__bytes__`` convention; callers who need to carry a literal
    dict with that shape should wrap it in another dict or use a
    different key.
    """
    obj = hnd.read_json_strict()
    if obj is None:
        return None
    return _convert_from_serializable(obj)


def _write_json(hnd: DataHandle, obj):
    """
    Write a Python object as JSON to a DataHandle.

    DataHandle.write_json was delegated to lingofuse.lf_io in a
    previous revision, so this function already benefits from the
    unified serialization and framing policy without further change.

    Before serialization, ``_convert_to_serializable`` transforms any
    Python ``bytes`` value into a ``{"__bytes__": <base64>}`` dict, so
    that binary data survives the JSON round-trip. The corresponding
    read path (``_read_json``) reverses the transformation.
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

    {!!!!!  BYTES ROUND-TRIP  !!!!!}
    Both directions of every exposed API apply the ``__bytes__``
    convention described in the module docstring: Python ``bytes``
    values are base64-encoded on the wire and decoded back to
    ``bytes`` on the receiving side, recursively through lists and
    dicts. This makes binary payloads work transparently.

    {!!!!!  AUTO SENDER IDENTITY (SIDE DATA)  !!!!!}
    User callbacks registered via ``expose`` receive the raw INPUT
    handle as a DataHandle. That handle exposes the sender's identity
    (which the framework injected as "side data" on the sender side)
    through two accessors:

        inp.get_p2p_uid()   -> bytes (exactly 32 bytes)
        inp.get_p2p_name()  -> str

    These accessors work ONLY on INPUT handles. See the module
    docstring for the full side-data contract, and the "whoami"
    pattern in the ``expose`` documentation.
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
    # Argument dispatch helper (shared by all four registration paths)
    # ------------------------------------------------------------------
    #
    # The logic below is IDENTICAL to the argument-shape rules that the
    # historical (pre-p2p) expose() decorator applied inline. It is
    # extracted here so that:
    #
    #   * App-bound Call        (App.register_call)
    #   * App-bound Notify      (App.register_notify)
    #   * Process-wide P2P Call (register_p2p_call)
    #   * Process-wide P2P Notify (register_p2p_notify)
    #
    # all share exactly one copy of the dispatch rules. This is a
    # pure refactor: the observable behaviour of the legacy
    # app-bound path is byte-for-byte unchanged.
    #
    # The dispatch rules, applied in order:
    #
    #   1. data is None              -> call func() with no arguments
    #   2. func takes exactly 1 arg:
    #          - data is a 1-element list -> call func(data[0])
    #          - otherwise                -> call func(data)
    #   3. func takes >1 args:
    #          - data is a list of the right length -> func(*data)
    #          - data is any other list             -> func(data)
    #          - data is a dict                     -> func(**data)
    #          - data is anything else              -> func(data)

    def _invoke_user_function(self, func: Callable, data: Any) -> Any:
        """
        Dispatch an incoming JSON payload to the user function.

        Returns whatever the user function returns. The caller decides
        whether the return value is meaningful (Call mode) or ignored
        (Notify mode).
        """
        sig = inspect.signature(func)
        params = list(sig.parameters.values())

        if data is None:
            return func()

        if len(params) == 1:
            if isinstance(data, list) and len(data) == 1:
                return func(data[0])
            return func(data)

        if isinstance(data, list):
            if len(data) == len(params):
                return func(*data)
            return func(data)

        if isinstance(data, dict):
            return func(**data)

        return func(data)

    # ------------------------------------------------------------------
    # Adapter factories
    # ------------------------------------------------------------------
    #
    # Adapters bridge the difference between a user function (which
    # takes plain Python arguments and, in Call mode, returns a value)
    # and the LingoFuse native callback contract (which receives
    # DataHandle objects and, in Call mode, writes to the output
    # handle). The adapter also isolates exceptions so that they never
    # escape into the C stack.
    #
    # The two factories differ only in their exception handling:
    #   * Call mode writes a JSON error object to the output handle
    #     before logging, so that the remote caller sees a structured
    #     error instead of an empty response.
    #   * Notify mode has no output handle; it logs only.
    #
    # {!!!!!  SIDE DATA IS PASSED THROUGH  !!!!!}
    # Both adapters build the input DataHandle with owned=False and
    # pass it to the user function unchanged. This means a user
    # function that opted into the 4-argument form
    # ``func(trigger, inp, out)`` can call ``inp.get_p2p_uid()`` and
    # ``inp.get_p2p_name()`` to read the sender's identity. The
    # side-data contract is documented on
    # ``lingofuse.core.DataHandle.get_p2p_uid``.

    def _make_notify_adapter(self, api_name: str, func: Callable) -> Callable:
        """
        Build a native Notify callback adapter around ``func``.

        The returned callable matches the ``LFNotifyFunc`` C signature
        ``(trigger, input) -> None``. Any exception raised by ``func``
        is caught and (in debug mode) printed; it is never allowed to
        propagate back into the C stack.
        """
        def _notify_adapter(trigger, inp: DataHandle):
            try:
                data = _read_json(inp)
                self._invoke_user_function(func, data)
            except Exception as e:
                # Adapter-level errors are logged but not propagated
                # (the callback wrapper in core.py would catch them
                # anyway).
                if self._debug:
                    print(
                        f"[Server] Notify adapter error for "
                        f"'{api_name}': {e}"
                    )
        return _notify_adapter

    def _make_call_adapter(self, api_name: str, func: Callable) -> Callable:
        """
        Build a native Call callback adapter around ``func``.

        The returned callable matches the ``LFCallFunc`` C signature
        ``(trigger, input, output) -> None``. The return value of
        ``func`` is serialized to JSON and written to the output
        handle. Any exception raised by ``func`` (or during JSON I/O)
        is converted into a JSON error object written to the output
        handle, and is never allowed to propagate back into the C
        stack.
        """
        def _call_adapter(trigger, inp: DataHandle, out: DataHandle):
            try:
                data = _read_json(inp)
                result = self._invoke_user_function(func, data)
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
        return _call_adapter

    # ------------------------------------------------------------------
    # API registration
    # ------------------------------------------------------------------

    def expose(self, api_name: str, notify: bool = False,
               description: str = "", p2p: bool = False):
        """
        Decorator: register a Python function as a remote API.

        Args:
            api_name: Unique API name (case-insensitive on the wire).
            notify: If True, register a one-way Notify API; otherwise a
                request-response Call API.
            description: Optional human-readable description.
            p2p: If False (default), register into the App-bound
                namespace owned by this Server's App. If True, register
                into the process-wide P2P namespace, which is
                independent of any App and reachable via UID or
                P2PName addressing only.

        The decorated function is called with arguments reconstructed
        from the incoming JSON payload. The dispatch rules are the same
        for both namespaces (and are unchanged from the historical
        behaviour of this decorator):

            - ``None`` / empty payload   -> call with no arguments
            - JSON list                  -> positional args
            - JSON object                -> keyword args
            - single-element list with 1-param function -> unwrap
            - anything else              -> passed as the first argument

        {!!!!!  CALLBACK SIGNATURES  !!!!!}
        For a Call API, the user function may be written in either of
        two forms:

            # Simple form: only the decoded JSON payload.
            @server.expose("add")
            def add(a, b):
                return a + b

            # Full form: also receives the raw INPUT/OUTPUT handles.
            @server.expose("whoami")
            def whoami(trigger, inp: DataHandle, out: DataHandle):
                ...

        The FULL form is required when the user function needs to
        read the sender's identity (side data) from the INPUT handle,
        or to write raw bytes directly to the OUTPUT handle. See the
        "whoami" pattern below.

        {!!!!!  THE whoami PATTERN (SIDE DATA)  !!!!!}
        The INPUT handle passed to a full-form callback carries the
        sender's identity as SIDE DATA, injected by the SENDER'S
        transport layer before transmission (Pascal side:
        TC40_LF_Client.Send_* ->
        TMemory_Param_Tool.Rebuild_UID_and_P2PName). The two fields
        are readable through:

            inp.get_p2p_uid()   -> bytes (exactly 32 bytes)
            inp.get_p2p_name()  -> str

        Both accessors work ONLY on INPUT handles. Calling them on a
        self-created handle or on an OUTPUT handle yields a null UID
        / empty string.

        The canonical use is the "whoami" probe, which lets a client
        learn its OWN UID (which the server sees as the sender's):

            from lingofuse.core import DataHandle

            @server.expose("whoami")
            def whoami(trigger, inp: DataHandle, out: DataHandle):
                caller_uid = inp.get_p2p_uid()    # 32-byte bytes
                caller_name = inp.get_p2p_name()  # str, '' if unset
                out.write_json({
                    "uid_hex": caller_uid.hex(),
                    "p2p_name": caller_name,
                })

        A client then calls ``whoami`` and caches the returned UID.
        Because the UID is regenerated on every TunnelLink, the
        client must re-probe after a link loss.

        {!!!!!  WHY THE UID IS SIDE DATA, NOT A HANDLE PROPERTY  !!!!!}
        The UID and P2P name are NOT stored on the handle object
        itself. They are metadata fields that the SENDER wrote into
        the payload header. The framework does not fabricate them on
        the receiver side. This is why a handle created by the
        receiver (via DataHandle(...) or
        DataHandle.create_permanent(...)) has no FromUID / FromP2PName
        at all: it was never sent anywhere.

        See ``lingofuse.core.DataHandle.get_p2p_uid`` for the full
        side-data contract.

        {!!!!!  NAMESPACE CHOICE  !!!!!}
        The two namespaces are orthogonal, and this flag is the ONLY
        thing that distinguishes them at the call site:

            # App-bound namespace:
            #   reachable via `client.app(<this server's app>).call(...)`
            #   and via UID addressing.
            #   Dies with the Server's App.
            @server.expose("add")
            def add(a, b): ...

            # Process-wide P2P namespace:
            #   reachable via UID addressing and P2PName addressing.
            #   NOT reachable via App-name addressing.
            #   Survives until the process exits, independent of the
            #   Server's App lifecycle.
            @server.expose("whoami", p2p=True)
            def whoami(): ...

        {!!!!!  WHY `p2p=True` DOES NOT TOUCH `self._app`  !!!!!}
        The App-bound registration path goes through
        ``App.register_call`` / ``App.register_notify``, which require
        the underlying App handle to be alive. The P2P path goes
        through the module-level ``register_p2p_call`` / ``register_p2p_notify``
        functions, which are process-wide and do not depend on any App.
        This means:

            * A ``p2p=True`` registration SUCCEEDS even if the Server's
              App has already been freed via ``Server.stop()``. This is
              intentional and matches the process-wide semantics of the
              underlying P2P namespace.
            * A ``p2p=True`` registration does NOT need to happen before
              ``Server.start()``; it can be performed at any point in
              the process lifetime, on or off a running Server.

        {!!!!!  LOOP-IMPORT NOTE  !!!!!}
        The P2P registration functions live in the package's
        ``__init__`` module. Because ``__init__`` itself imports this
        module (to expose ``Server``), the import of those two
        functions is performed lazily, inside the decorator, at the
        moment the user actually calls ``expose(p2p=True)``. By that
        time the package is fully initialised, so a plain
        ``from . import register_p2p_call`` succeeds.

        {!!!!!  BYTES HANDLING  !!!!!}
        Every payload read by the adapter goes through
        ``_read_json``, which restores base64-encoded ``bytes`` values
        to their original form recursively. See the module docstring
        section "BYTES ROUND-TRIP FIX" for the full contract.

        The same ``_read_json`` uses ``DataHandle.read_json_strict()``,
        so a malformed JSON payload raises ``RuntimeError`` instead of
        being silently treated as a no-argument dispatch. The
        surrounding adapter converts the exception into a structured
        ``{"__error__": ...}`` response (Call mode) or logs it and
        drops the notification (Notify mode).
        """
        def decorator(func: Callable):
            if notify:
                adapter = self._make_notify_adapter(api_name, func)
                if p2p:
                    from . import register_p2p_notify
                    register_p2p_notify(api_name, adapter, description)
                else:
                    self._app.register_notify(
                        api_name, adapter, description
                    )
            else:
                adapter = self._make_call_adapter(api_name, func)
                if p2p:
                    from . import register_p2p_call
                    register_p2p_call(api_name, adapter, description)
                else:
                    self._app.register_call(
                        api_name, adapter, description
                    )
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

        The arguments are serialized via ``_write_json``, which applies
        the ``__bytes__`` convention to any bytes value (recursively).
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

        The arguments are serialized via ``_write_json``, which applies
        the ``__bytes__`` convention to any bytes value (recursively).
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

        The response is read via ``_read_json``, which restores any
        base64-encoded bytes values recursively.
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
            result = _read_json(resp)
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

        {!!!!!  P2P NAMESPACE IS UNAFFECTED  !!!!!}
        Process-wide P2P APIs registered via ``expose(p2p=True)`` are
        NOT torn down by ``stop()``. They live on the process-wide
        ``LF_P2P_APP`` and are destroyed only by ``LF_Shutdown()``.
        ``stop(full_cleanup=True)`` therefore removes them as a side
        effect of the global shutdown, but ``stop(full_cleanup=False)``
        does not.

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