# -*- coding: utf-8 -*-
"""
Network event API for the LingoFuse Python bindings.

This module wraps ``LF_Set_Network_Event``, which installs a pair of
process-global callbacks that fire when a LingoFuse client transitions
between the "online" and "offline" states.

==================== CRITICAL THREADING CONTRACT ====================
The callbacks are executed on a BACKGROUND C WORKER THREAD - not the
main thread, and not the thread that installed the callback.

Therefore:
    * Do NOT touch UI components directly.
    * Do NOT call any blocking LingoFuse function (LF_Call, LF_LocalCall,
      LF_PrepareDone, LF_Shutdown) inside the callback - it will deadlock.
    * Offload heavy work to a separate thread, or use the queue-based
      consumer pattern (NetworkEventQueue) provided by this module.

The ``addr`` argument is a Python ``str`` that has already been decoded
from UTF-8. It is safe to hold long-term.

==================== SEMANTIC NOTES ====================
* "Connect"    is NOT the TCP handshake completion. It fires the first
               time the client receives a service API-info broadcast,
               i.e. the earliest point at which remote calls can be
               routed.
* "Disconnect" fires once per physical link loss. Automatic reconnects
               will NOT emit a Disconnect for the reconnect attempt
               itself, but will emit a new Connect once the client is
               online again.

==================== {!!!!!  REPLACE SEMANTICS  !!!!!} ==============
``set_network_event(...)`` is a REPLACE operation, not a PATCH.

Calling it twice replaces the previously installed callbacks entirely,
even if the second call leaves some arguments as None::

    # --- Minimal example of the pitfall ---
    set_network_event(on_connect=cb1)          # cb1 installed, no disconnect
    set_network_event(on_disconnect=cb2)       # -> cb1 is now UNINSTALLED

After the second call, ``cb1`` will never fire again, and only ``cb2``
is active. If you want both callbacks, install them in a single call::

    set_network_event(on_connect=cb1, on_disconnect=cb2)

There is no "patch" API. To change only one side, pass the current
callback for the other side, or call ``clear_network_event()`` first.

==================== THREE USAGE MODES ====================
1. Function callbacks (lowest level)::

       lingofuse.set_network_event(
           on_connect=lambda addr: print("+", addr),
           on_disconnect=lambda addr: print("-", addr),
       )
       ...
       lingofuse.clear_network_event()

2. Object-oriented listener::

       class MyListener(lingofuse.NetworkEventListener):
           def on_connect(self, addr): ...
           def on_disconnect(self, addr): ...

       lingofuse.set_network_event(listener=MyListener())

3. Queue-based consumer (recommended for servers)::

       q = lingofuse.NetworkEventQueue.global_instance()
       q.install()
       try:
           while running:
               try:
                   evt_type, addr = q.get(timeout=1.0)
               except queue.Empty:
                   continue
               ...
       finally:
           q.uninstall()

==================== GLOBAL SCOPE ====================
``LF_Set_Network_Event`` is a process-global slot. There is no
per-client registration API. Installing a listener affects every
LingoFuse client in the current process.
"""

from __future__ import annotations

import logging
import queue
import threading
from typing import Any, Callable, Optional, Tuple

from ._lf_native import LF_Set_Network_Event, LFNetworkEventFunc


# Module-level logger. All status output goes through this logger
# (in English) so the caller can control verbosity via the standard
# ``logging`` configuration.
_log = logging.getLogger("lingofuse.network_events")


# ======================================================================
# Module-level strong references
# ======================================================================
#
# ctypes callbacks are plain Python objects. If we pass them to
# LF_Set_Network_Event without keeping a reference, the garbage
# collector may destroy them while the C library still holds their
# function pointers - leading to a crash on the next trigger.
#
# We therefore keep all ctypes callback objects (and the user-supplied
# callables they wrap) alive in this module-level dictionary, guarded
# by a lock to keep install / clear atomic.
#
# {!!!!!  NO CALLBACK CACHE  !!!!!}
# Each call to set_network_event() builds fresh ctypes callback objects
# rather than trying to cache them by user-callable identity. This is a
# deliberate design choice:
#   * Network event installation is a once-per-process operation, so
#     the cost of rebuilding is irrelevant.
#   * The user callable is often an anonymous lambda or a bound method,
#     neither of which has a stable identity we could safely use as a
#     cache key.
#   * Avoiding the cache eliminates a class of subtle bugs where a
#     stale callback object survives an install/clear cycle.
#
# NOTE ON TYPE ANNOTATIONS:
# ``LFNetworkEventFunc`` is a runtime object produced by
# ``ctypes.CFUNCTYPE(...)``. Static analysers such as Pylance do not
# treat it as a type, so we annotate the corresponding variables as
# ``Any`` to avoid ``reportInvalidTypeForm`` warnings. The runtime
# behaviour is identical.
# ======================================================================

_keepalive_lock = threading.Lock()
_keepalive: dict = {
    "c_connect": None,        # Any (LFNetworkEventFunc instance) or None
    "c_disconnect": None,     # Any (LFNetworkEventFunc instance) or None
    "user_connect": None,     # callable or None
    "user_disconnect": None,  # callable or None
}


# ======================================================================
# Adapter: user callable -> ctypes callback
# ======================================================================

def _build_c_callback(
    user_cb: Optional[Callable[[str], None]],
    event_name: str,
) -> Optional[Any]:
    """
    Wrap a user-supplied callable into a ctypes callback.

    The wrapper:
      * Decodes the incoming UTF-8 bytes into a Python ``str``.
      * Isolates all exceptions - nothing is allowed to propagate back
        into the C stack.
      * Logs any failure via the module logger.

    Returns:
        A ``LFNetworkEventFunc`` instance (or ``None`` when
        ``user_cb`` is ``None``). The return type is annotated as
        ``Optional[Any]`` because ``LFNetworkEventFunc`` is a runtime
        value, not a static type; the underlying library interprets a
        NULL function pointer as "callback not installed".

    {!!!!!  ARGUMENT DECODING  !!!!!}
    The C side declares the callback parameter as ``const char*``, and
    the ctypes prototype uses ``c_char_p``. ctypes automatically
    converts a ``c_char_p`` *callback argument* into a fresh Python
    ``bytes`` object - it does not stop at an embedded NUL, and it does
    not include the terminating NUL in the returned bytes. We therefore
    do NOT need to strip any trailing ``\\x00`` here; a simple
    ``.decode("utf-8")`` is enough.
    """
    if user_cb is None:
        return None

    def _c_callback(addr_bytes):
        # ctypes has already produced a bytes object that does not
        # include the trailing NUL. Guard against a None value just in
        # case an older ctypes build behaves differently.
        try:
            addr = addr_bytes.decode("utf-8") if addr_bytes else ""
            user_cb(addr)
        except Exception:
            # We must never let an exception escape into C code.
            # The library swallows exceptions silently, but ctypes
            # would print to stderr and could destabilize the
            # interpreter. Log defensively instead.
            _log.exception(
                "network event '%s' callback raised an exception; "
                "the exception has been suppressed",
                event_name,
            )

    return LFNetworkEventFunc(_c_callback)


# ======================================================================
# Public API: install / clear
# ======================================================================

def set_network_event(
    on_connect: Optional[Callable[[str], None]] = None,
    on_disconnect: Optional[Callable[[str], None]] = None,
    listener=None,
) -> None:
    """
    Install global network event callbacks.

    Args:
        on_connect:
            Called when a LingoFuse client becomes online.
            Signature: ``fn(addr: str) -> None``.
        on_disconnect:
            Called when a LingoFuse client goes offline.
            Signature: ``fn(addr: str) -> None``.
        listener:
            Alternatively, pass an object exposing ``on_connect`` and/or
            ``on_disconnect`` methods. If provided, the explicit
            ``on_connect`` / ``on_disconnect`` arguments are ignored.

    Threading contract:
        The callbacks run on a background C worker thread. Do not touch
        UI from inside them. Do not call blocking LingoFuse functions.
        Offload heavy work to another thread, or use
        :class:`NetworkEventQueue`.

    Timing:
        It is strongly recommended to call this BEFORE ``LF_PrepareDone``
        or AFTER ``LF_ExitMainThread``, so that no network activity races
        with the installation. The underlying ``LF_Set_Network_Event``
        is a plain pointer store without locking.

    {!!!!!  REPLACE SEMANTICS  !!!!!}
    This is a REPLACE operation, not a PATCH. Calling it again discards
    any previously installed callbacks, including those whose
    corresponding argument is ``None`` in the new call::

        set_network_event(on_connect=cb1)      # cb1 active, disconnect=none
        set_network_event(on_disconnect=cb2)   # cb1 removed, only cb2 active

    To install both at once, pass both arguments in a single call.
    Use :func:`clear_network_event` to uninstall completely.
    """
    if listener is not None:
        on_connect = getattr(listener, "on_connect", None)
        on_disconnect = getattr(listener, "on_disconnect", None)

    with _keepalive_lock:
        _keepalive["user_connect"] = on_connect
        _keepalive["user_disconnect"] = on_disconnect
        _keepalive["c_connect"] = _build_c_callback(on_connect, "connect")
        _keepalive["c_disconnect"] = _build_c_callback(
            on_disconnect, "disconnect"
        )

        LF_Set_Network_Event(
            _keepalive["c_connect"],
            _keepalive["c_disconnect"],
        )

        _log.info(
            "network event callbacks installed "
            "(connect=%s, disconnect=%s)",
            "yes" if on_connect is not None else "no",
            "yes" if on_disconnect is not None else "no",
        )


def clear_network_event() -> None:
    """
    Uninstall all network event callbacks.

    Equivalent to ``LF_Set_Network_Event(None, None)``. After this call,
    no user callback will fire.

    Safe to call multiple times.
    """
    with _keepalive_lock:
        LF_Set_Network_Event(None, None)

        _keepalive["c_connect"] = None
        _keepalive["c_disconnect"] = None
        _keepalive["user_connect"] = None
        _keepalive["user_disconnect"] = None

        _log.info("network event callbacks cleared")


def is_network_event_installed() -> bool:
    """
    Return ``True`` if at least one callback is currently installed.
    """
    with _keepalive_lock:
        return (
            _keepalive["c_connect"] is not None
            or _keepalive["c_disconnect"] is not None
        )


# ======================================================================
# OOP-style listener base class
# ======================================================================

class NetworkEventListener:
    """
    Base class for object-oriented network event listeners.

    Subclass and override ``on_connect`` / ``on_disconnect`` as needed.
    Both methods are optional.

    Example::

        class MyListener(NetworkEventListener):
            def on_connect(self, addr):
                print("Connected:", addr)
            def on_disconnect(self, addr):
                print("Disconnected:", addr)

        set_network_event(listener=MyListener())

    Both methods run on the background C worker thread. See the module
    docstring for the full threading contract.
    """

    def on_connect(self, addr: str) -> None:
        """Called when a client becomes online. Override in subclass."""
        pass

    def on_disconnect(self, addr: str) -> None:
        """Called when a client goes offline. Override in subclass."""
        pass


# ======================================================================
# Queue-based consumer
# ======================================================================

class NetworkEventQueue:
    """
    Thread-safe queue that receives network events.

    This is the recommended pattern for server-side applications where
    the callback thread must not be blocked by user logic.

    Usage::

        q = NetworkEventQueue.global_instance()
        q.install()
        try:
            while running:
                try:
                    evt_type, addr = q.get(timeout=1.0)
                    # evt_type is either "connect" or "disconnect"
                    ...
                except queue.Empty:
                    continue
        finally:
            q.uninstall()

    The queue is bounded; when full, the producer (running on a C worker
    thread) blocks. This provides natural back-pressure so that a slow
    consumer cannot cause unbounded memory growth.

    {!!!!!  GLOBAL SINGLETON  !!!!!}
    The underlying ``LF_Set_Network_Event`` is a single process-global
    slot. You should therefore use :meth:`global_instance` rather than
    creating multiple queues with independent ``install()`` calls - the
    last install would overwrite all the previous ones.
    """

    #: Process-wide singleton instance.
    _global_instance: "Optional[NetworkEventQueue]" = None
    _global_lock = threading.Lock()

    #: Default maximum number of pending events.
    DEFAULT_MAX_SIZE = 10000

    def __init__(self, max_size: Optional[int] = None):
        if max_size is None:
            max_size = self.DEFAULT_MAX_SIZE
        self._queue: "queue.Queue[Tuple[str, str]]" = queue.Queue(
            maxsize=max_size
        )
        self._installed = False
        self._lock = threading.Lock()

    # ----------------------------------------------------------------
    # Singleton access
    # ----------------------------------------------------------------

    @classmethod
    def global_instance(cls) -> "NetworkEventQueue":
        """
        Return the process-wide singleton instance.

        The underlying ``LF_Set_Network_Event`` is a global slot, so a
        single global queue is the natural design. Do not create
        multiple independent instances and call ``install()`` on each -
        they would overwrite one another's callbacks.
        """
        with cls._global_lock:
            if cls._global_instance is None:
                cls._global_instance = cls()
            return cls._global_instance

    # ----------------------------------------------------------------
    # Install / uninstall
    # ----------------------------------------------------------------

    def install(self) -> None:
        """
        Install this queue as the receiver of network events.

        Safe to call multiple times - subsequent calls are no-ops.

        {!!!!!  OVERWRITES EXISTING CALLBACKS  !!!!!}
        If another network event callback is already installed (either
        because the user called :func:`set_network_event` directly, or
        because a different queue installed itself first), this method
        will OVERWRITE it. A warning is emitted in that case, so that
        the previous installation does not silently disappear.

        If you need both the queue and another callback, use the queue
        as the single entry point: register the queue, and add the
        other logic to whatever consumes from it.
        """
        with self._lock:
            if self._installed:
                return

            if is_network_event_installed():
                _log.warning(
                    "NetworkEventQueue.install() is overwriting a "
                    "previously installed network event callback. "
                    "The previous callback will no longer fire. If you "
                    "intended to keep both, uninstall the previous one "
                    "explicitly or use a single entry point."
                )

            set_network_event(
                on_connect=lambda addr: self._enqueue("connect", addr),
                on_disconnect=lambda addr: self._enqueue(
                    "disconnect", addr
                ),
            )
            self._installed = True
            _log.info(
                "NetworkEventQueue installed (maxsize=%d)",
                self._queue.maxsize,
            )

    def uninstall(self) -> None:
        """
        Stop receiving network events.

        Safe to call multiple times. Does not drain the queue.
        """
        with self._lock:
            if not self._installed:
                return
            clear_network_event()
            self._installed = False
            _log.info("NetworkEventQueue uninstalled")

    # ----------------------------------------------------------------
    # Producer side (called on the C worker thread)
    # ----------------------------------------------------------------

    def _enqueue(self, evt_type: str, addr: str) -> None:
        """
        Enqueue one event. Runs on the background C worker thread.

        Uses a blocking ``put`` so that a full queue applies back-
        pressure instead of dropping events or growing without bound.
        """
        try:
            self._queue.put((evt_type, addr), block=True)
        except Exception:
            # Should not normally happen with block=True. Log
            # defensively rather than letting the exception escape
            # into C.
            _log.exception("failed to enqueue network event")

    # ----------------------------------------------------------------
    # Consumer side
    # ----------------------------------------------------------------

    def get(
        self,
        block: bool = True,
        timeout: Optional[float] = None,
    ) -> Tuple[str, str]:
        """
        Consume one event.

        Returns a tuple ``(event_type, addr)`` where ``event_type`` is
        either ``"connect"`` or ``"disconnect"``.

        Raises :class:`queue.Empty` if ``block=False`` and no event is
        available, or if the ``timeout`` expires.
        """
        return self._queue.get(block=block, timeout=timeout)

    def empty(self) -> bool:
        """Return ``True`` if the queue currently holds no events."""
        return self._queue.empty()

    def qsize(self) -> int:
        """Return the approximate number of pending events."""
        return self._queue.qsize()

    def clear(self) -> None:
        """Drain all pending events without processing them."""
        while True:
            try:
                self._queue.get_nowait()
            except queue.Empty:
                break

    # ----------------------------------------------------------------
    # Context manager support
    # ----------------------------------------------------------------

    def __enter__(self) -> "NetworkEventQueue":
        self.install()
        return self

    def __exit__(self, *exc_info):
        self.uninstall()


# ======================================================================
# Module-level convenience
# ======================================================================

def get_network_event_queue() -> NetworkEventQueue:
    """Return the process-wide :class:`NetworkEventQueue` singleton."""
    return NetworkEventQueue.global_instance()