# -*- coding: utf-8 -*-
"""
lingofuse.async_support - Safe lifetime management and modern async
bridging for LingoFuse's asynchronous call primitives.

This module is the subsystem that sits between the ctypes-level
async callback mechanism (``LF_Async_Call`` and its UID_* /
P2PName_* variants) and modern Python async programming. It exists
because the naive approach -- create a ctypes callback, hand it to
the C library, drop the Python reference as soon as the request
returns -- is fundamentally unsafe.

==================== WHY THIS SUBSYSTEM EXISTS ====================

The LingoFuse C library holds a RAW FUNCTION POINTER to the callback
you register. It does NOT hold a Python reference to the ctypes
callback object. Three distinct hazards arise from this:

  1. PREMATURE RELEASE ON TIMEOUT

     A timed-out request is NOT cancelled by the C library. The
     framework will still invoke the callback when (or if) the
     response eventually arrives. If you drop the Python callback
     object the moment your timeout fires, the C side is left
     holding a dangling pointer, and the next invocation segfaults.

     The original ``address.py`` had exactly this bug in
     ``Target.sequenced_call``: it released the callback holder on
     timeout while the C request was still in flight.

  2. LEAK ON DISPATCH FAILURE

     If the C library rejects the request before dispatching it
     (returns 0 instead of 1), the callback will NEVER fire. A naive
     "wait for the callback to release the object" policy leaks the
     Python object forever.

     The original ``address.py`` had this bug too: ``async_call``
     registered the holder in a keepalive dict and never released it
     if the dispatch returned 0.

  3. DOUBLE-RELEASE RACES

     The caller thread (on timeout) and the C worker thread (on
     callback) can race to release the same object. Without a state
     machine, this leads to a use-after-free.

``AsyncBridge`` addresses all three hazards:

  * Every operation is wrapped in an :class:`AsyncOp` with an
    explicit state machine (PENDING -> FIRED | ABANDONED |
    NOT_QUEUED).

  * Only the bridge releases an op, and only after one of:
        - the callback has fired (state FIRED), or
        - a configurable grace period has elapsed since the timeout
          fired (state ABANDONED), giving any late callback a
          chance to arrive on a still-valid Python object.

  * Dispatch failure releases the op immediately (state
    NOT_QUEUED), because the C side never received the pointer.

==================== ARCHITECTURE ====================

    CallFuture        concurrent.futures.Future subclass with an
                      extra ``abandoned`` flag.

    AsyncOp           Per-operation state holder. Owns the ctypes
                      callback object and (optionally) the Future.
                      Registered with the bridge.

    AsyncBridge       Process-wide singleton. Holds every live op;
                      runs a background reclamation thread.

    make_future_op        Build an op + CallFuture pair.

    make_legacy_op        Build an op for the traditional "user
                          provides callback" style.

    run_async_with_future One-stop helper: build op+future, issue
                          the C request, apply the timeout, and
                          return the future.

    await_future          asyncio bridge: await a CallFuture from
                          inside a coroutine.

==================== THREADING MODEL ====================

    - The caller thread creates the op, registers it, and issues
      the C request.

    - The C worker thread invokes the ctypes callback when the
      result is ready. The callback body only: deserializes the
      result, resolves the Future, and notifies the bridge.

    - The bridge's reclamation thread wakes up periodically to
      process timeouts and pending releases.

    - No user code runs on the C worker thread. If a caller wants
      to process the result, they either block on
      ``future.result()``, attach a done-callback to the Future,
      or await the asyncio wrapper (which marshals the resolution
      onto the event loop).

The bridge uses one ``threading.Lock`` for the op registry and one
``threading.Condition`` for the timeout/release queues. Neither is
ever held across a user callback.

==================== CALLBACK CONTRACT (RESTATED) ====================

The ctypes callback installed by this module runs on a TCompute
worker thread. It MUST NOT block, and MUST NOT call any synchronous
LingoFuse function (LF_Call / LF_Notify / LF_LocalCall / LF_PrepareDone
/ LF_Shutdown). The callback body in this module obeys that
contract by construction.

==================== CONFIGURATION ====================

Two environment variables are read ONCE, at module import:

    LINGOFUSE_ASYNC_RECLAIM_GRACE

        Seconds to keep an abandoned op alive after its timeout
        fires, giving any in-flight C callback a chance to arrive
        on a still-valid Python object. Default: 60. Must be >= 0.

    LINGOFUSE_ASYNC_RECLAIM_PERIOD

        Seconds between reclamation sweeps. Default: 1.0. Must be
        > 0.05.

Both are clamped to their minimum with a WARNING if set below.

==================== DIAGNOSTICS ====================

``AsyncBridge.instance().stats()`` returns a dict with current
counts. Intended for tests and production dashboards:

    {
        "total":          <int>,  # live ops
        "pending":        <int>,  # awaiting callback
        "fired":          <int>,  # callback fired, awaiting release
        "abandoned":      <int>,  # timed out, awaiting grace expiry
        "not_queued":     <int>,  # dispatch failed
        "released_total": <int>,  # cumulative released
        "grace_seconds":  <float>,
        "period_seconds": <float>,
    }

==================== WHAT THIS MODULE DOES NOT DO ====================

  * It does NOT cancel C-side requests. ``Future.cancel()`` only
    affects the Python object; the C request continues. The op is
    still held alive until the callback fires or grace expires.

  * It does NOT provide a timeout on the C side. ``LF_Async_Call``
    has no timeout parameter; the timeout applied here is purely a
    Python-side decision to stop waiting. The C request may still
    complete, and if it does, its result is discarded.

  * It does NOT reorder or batch callbacks. Each op is independent.

All comments, log messages, and status output are in English.
"""

from __future__ import annotations

import asyncio
import collections
import concurrent.futures
import logging
import os
import threading
import time
from typing import Any, Callable, Optional, Tuple

from ._lf_native import LFAsyncCallOnResult
from .errors import LingoFuseError, TimeoutError


_log = logging.getLogger("lingofuse.async_support")


# ======================================================================
# Configuration
# ----------------------------------------------------------------------
# Both values are read exactly once, at module import. Changing the
# environment afterwards has no effect. Tests that need to exercise
# a non-default grace period should set the environment variable
# before importing this module, or (for unit tests) assign to the
# bridge instance's ``grace_seconds`` / ``period_seconds`` directly.
# ======================================================================

def _env_float(
    name: str,
    default: float,
    minimum: Optional[float] = None,
) -> float:
    """
    Read a float from the environment, with a default and optional
    minimum. A malformed value logs a WARNING and falls back to the
    default. A value below the minimum is clamped to the minimum
    with a WARNING.
    """
    raw = os.environ.get(name)
    if raw is None:
        return default
    try:
        value = float(raw)
    except ValueError:
        _log.warning(
            "Environment variable %s=%r is not a float; "
            "using default %r",
            name, raw, default,
        )
        return default
    if minimum is not None and value < minimum:
        _log.warning(
            "Environment variable %s=%r is below minimum %r; "
            "clamping to %r",
            name, raw, minimum, minimum,
        )
        return minimum
    return value


_DEFAULT_GRACE_SECONDS: float = _env_float(
    "LINGOFUSE_ASYNC_RECLAIM_GRACE",
    60.0,
    minimum=0.0,
)

_DEFAULT_PERIOD_SECONDS: float = _env_float(
    "LINGOFUSE_ASYNC_RECLAIM_PERIOD",
    1.0,
    minimum=0.05,
)


# ======================================================================
# CallFuture
# ======================================================================

class CallFuture(concurrent.futures.Future):
    """
    Future returned by ``run_async_with_future`` and by the
    Future-based methods of :class:`~lingofuse.address.Target`.

    Adds a single extra flag, ``abandoned``, which distinguishes
    two different ways the Future can end up without a result:

      * The caller cancelled it via ``future.cancel()``. The C
        request may or may not still be in flight.

      * The timeout expired before the callback arrived.
        ``future.abandoned`` becomes True. The C request is still
        in flight, and the callback may still fire later; when it
        does, its result is silently discarded because the Future
        is already resolved with a
        :class:`~lingofuse.errors.TimeoutError`.

    Callers who need to distinguish "cancelled" from "timed out"
    should inspect ``future.abandoned`` after catching the
    exception.

    The flag is set by the timeout machinery; callers do not set it
    directly.
    """

    __slots__ = ("_abandoned", "_abandoned_lock")

    def __init__(self) -> None:
        super().__init__()
        self._abandoned = False
        self._abandoned_lock = threading.Lock()

    @property
    def abandoned(self) -> bool:
        """
        True if the timeout expired before the result arrived.

        Thread-safe: the flag may be set by the bridge's reclamation
        thread while the caller thread reads it.
        """
        with self._abandoned_lock:
            return self._abandoned

    def _mark_abandoned(self) -> None:
        """Internal: mark this Future as abandoned. Idempotent."""
        with self._abandoned_lock:
            self._abandoned = True


# ======================================================================
# AsyncOp
# ======================================================================

class AsyncOp:
    """
    A single outstanding asynchronous operation.

    Owns the ctypes callback object and, optionally, the
    :class:`CallFuture` that receives the result. Registered with
    :class:`AsyncBridge` on creation; released by the bridge once
    the state machine permits.

    State machine
    -------------

        PENDING  --(callback fires)-->  FIRED
        PENDING  --(timeout fires)-->   ABANDONED --(callback fires)--> FIRED
        PENDING  --(dispatch fails)-->  NOT_QUEUED

    FIRED means the callback has completed its Python-side work
    (whether it delivered a result or was dropped because the op
    had already been abandoned). Once FIRED, the op is scheduled
    for immediate release.

    ABANDONED means a timeout fired while the op was still
    PENDING. The op is held alive for ``grace_seconds`` before
    release, giving any late callback a chance to arrive on a
    still-valid Python object.

    NOT_QUEUED means the C dispatch failed before the callback was
    installed. The op is released immediately.

    All state transitions are performed under ``_state_lock``.
    """

    STATE_PENDING = "pending"
    STATE_FIRED = "fired"
    STATE_ABANDONED = "abandoned"
    STATE_NOT_QUEUED = "not_queued"

    __slots__ = (
        "_deliver_fn",
        "_c_callback",
        "_future",
        "_state",
        "_state_lock",
        "_key",
        "_created_at",
    )

    def __init__(
        self,
        deliver_fn: Callable[[Any, Optional[Exception]], None],
        c_callback: Any,
        future: Optional[CallFuture] = None,
    ) -> None:
        self._deliver_fn = deliver_fn
        self._c_callback = c_callback
        self._future = future
        self._state = self.STATE_PENDING
        self._state_lock = threading.Lock()
        self._key: Optional[int] = None
        self._created_at = time.monotonic()

    @property
    def c_callback(self) -> Any:
        """The ctypes callback object to pass to the C library."""
        return self._c_callback

    @property
    def future(self) -> Optional[CallFuture]:
        """The Future this op resolves, or None for legacy ops."""
        return self._future

    @property
    def state(self) -> str:
        """Current state; thread-safe."""
        with self._state_lock:
            return self._state

    def mark_not_queued(self) -> None:
        """
        Transition to NOT_QUEUED and schedule immediate release.

        Called by the caller thread when the C dispatch returned a
        value other than 1, i.e. the callback will never fire.

        Safe to call multiple times; subsequent calls are no-ops.
        """
        with self._state_lock:
            if self._state != self.STATE_PENDING:
                return
            self._state = self.STATE_NOT_QUEUED
        AsyncBridge.instance()._schedule_release_now(self)

    def _invoke_from_c(
        self,
        result: Any,
        error: Optional[Exception],
    ) -> None:
        """
        Called from the C worker thread when the callback fires.

        Transitions to FIRED (or, if the op was already ABANDONED,
        still transitions to FIRED but drops the result), then
        invokes the deliver function exactly once.
        """
        with self._state_lock:
            current = self._state
            if current == self.STATE_FIRED:
                # Second invocation; by contract this cannot happen,
                # but treat it as a no-op so a buggy C side cannot
                # corrupt our state.
                return
            if current == self.STATE_NOT_QUEUED:
                # Dispatch already failed; ignore.
                return
            if current == self.STATE_ABANDONED:
                # Late callback after timeout. The result is dropped,
                # but we now know the C side has completed its
                # invocation, so we can release immediately instead
                # of waiting for the grace period to expire.
                self._state = self.STATE_FIRED
                AsyncBridge.instance()._schedule_release_now(self)
                return
            # current == STATE_PENDING: normal path.
            self._state = self.STATE_FIRED

        try:
            self._deliver_fn(result, error)
        except Exception:
            # A failure here means the caller's callback (or our
            # internal Future-resolution helper) raised. We must
            # never let that escape into the C stack.
            _log.exception("AsyncOp delivery callback raised")
        finally:
            AsyncBridge.instance()._schedule_release_now(self)

    def _abandon(self) -> bool:
        """
        Transition to ABANDONED. Returns True if the transition
        actually happened (i.e. the op was PENDING), False otherwise.

        Called by the bridge's reclamation thread.
        """
        with self._state_lock:
            if self._state != self.STATE_PENDING:
                return False
            self._state = self.STATE_ABANDONED
        return True


# ======================================================================
# AsyncBridge
# ======================================================================

def _split_expired(
    queue: "collections.deque[Tuple[float, AsyncOp]]",
    now: float,
) -> Tuple[list, "collections.deque[Tuple[float, AsyncOp]]"]:
    """
    Split a deadline queue into (expired items, remaining items).

    The expired list preserves the order in which items were
    enqueued; the remaining deque is rebuilt with the same order.
    """
    expired: list = []
    remaining: "collections.deque[Tuple[float, AsyncOp]]" = (
        collections.deque()
    )
    while queue:
        deadline, op = queue.popleft()
        if deadline <= now:
            expired.append(op)
        else:
            remaining.append((deadline, op))
    return expired, remaining


class AsyncBridge:
    """
    Process-wide manager for every outstanding :class:`AsyncOp`.

    The bridge is a singleton. It holds the only strong reference
    to each op's ctypes callback object for as long as the C library
    might invoke it, and releases that reference once the op's state
    machine permits.

    Public surface:

        AsyncBridge.instance()          -- get the singleton
        AsyncBridge.shutdown_instance() -- release the singleton
        bridge.register(op)             -- register an op
        bridge.schedule_timeout(op, ms) -- arm a timeout
        bridge.stats()                  -- diagnostic counters
        bridge.shutdown()               -- release everything

    The bridge is not intended to be subclassed or instantiated
    directly by user code; use :meth:`instance`.
    """

    _instance: "Optional[AsyncBridge]" = None
    _instance_lock = threading.Lock()

    @classmethod
    def instance(cls) -> "AsyncBridge":
        """Return the process-wide singleton, creating it on first use."""
        with cls._instance_lock:
            if cls._instance is None:
                cls._instance = cls()
            return cls._instance

    @classmethod
    def shutdown_instance(cls) -> None:
        """
        Release the singleton. Safe to call multiple times.

        Intended for tests and for process teardown. After this
        call, the next :meth:`instance` invocation creates a fresh
        bridge with an empty registry.
        """
        with cls._instance_lock:
            inst = cls._instance
            cls._instance = None
        if inst is not None:
            inst.shutdown()

    def __init__(self) -> None:
        self._handles: dict = {}
        self._handles_lock = threading.Lock()
        self._counter = 0
        self._release_count = 0
        self._release_queue: "collections.deque[Tuple[float, AsyncOp]]" = (
            collections.deque()
        )
        self._timeout_queue: "collections.deque[Tuple[float, AsyncOp]]" = (
            collections.deque()
        )
        self._cv = threading.Condition()
        self._shutdown = False

        # Exposed as attributes rather than read from the module
        # constants so that tests can override them per-instance
        # without re-importing the module.
        self.grace_seconds: float = _DEFAULT_GRACE_SECONDS
        self.period_seconds: float = _DEFAULT_PERIOD_SECONDS

        self._thread = threading.Thread(
            target=self._reclaim_loop,
            name="LingoFuseAsyncBridge",
            daemon=True,
        )
        self._thread.start()

    # ------------------------------------------------------------------
    # Registration and scheduling
    # ------------------------------------------------------------------

    def register(self, op: AsyncOp) -> None:
        """
        Register an op with the bridge.

        Must be called before the op's ctypes callback is handed to
        the C library, so that the C side can never invoke a
        callback the bridge does not know about.
        """
        with self._handles_lock:
            self._counter += 1
            key = self._counter
            op._key = key
            self._handles[key] = op

    def schedule_timeout(self, op: AsyncOp, timeout_ms: int) -> None:
        """
        Arm a Python-side timeout on the given op.

        When the timeout fires, the op is transitioned to ABANDONED,
        the associated Future (if any) is resolved with a
        :class:`~lingofuse.errors.TimeoutError`, and the op is held
        alive for ``grace_seconds`` before release.
        """
        if timeout_ms <= 0:
            return
        deadline = time.monotonic() + timeout_ms / 1000.0
        with self._cv:
            self._timeout_queue.append((deadline, op))
            self._cv.notify()

    def _schedule_release_now(self, op: AsyncOp) -> None:
        """Schedule immediate release (deadline = now)."""
        with self._cv:
            self._release_queue.append((time.monotonic(), op))
            self._cv.notify()

    def _schedule_release_after_grace(self, op: AsyncOp) -> None:
        """Schedule release after the configured grace period."""
        deadline = time.monotonic() + self.grace_seconds
        with self._cv:
            self._release_queue.append((deadline, op))
            self._cv.notify()

    # ------------------------------------------------------------------
    # Reclamation thread
    # ------------------------------------------------------------------

    def _reclaim_loop(self) -> None:
        """
        Background loop: process expired timeouts and pending
        releases.

        Runs until :meth:`shutdown` sets the shutdown flag. The
        thread is a daemon, so it does not prevent interpreter exit.
        """
        while True:
            with self._cv:
                if self._shutdown:
                    return
                if not self._release_queue and not self._timeout_queue:
                    # Nothing to do; wait up to one period. The
                    # wait also acts as a safety net for any op that
                    # was added without notifying (should not happen).
                    self._cv.wait(timeout=self.period_seconds)
                if self._shutdown:
                    return

                now = time.monotonic()
                ready_releases, self._release_queue = _split_expired(
                    self._release_queue, now
                )
                ready_timeouts, self._timeout_queue = _split_expired(
                    self._timeout_queue, now
                )

            for op in ready_timeouts:
                self._handle_timeout(op)
            for op in ready_releases:
                self._release_op(op)

    def _handle_timeout(self, op: AsyncOp) -> None:
        """
        Handle an expired timeout. Called on the reclamation thread.
        """
        if not op._abandon():
            # The op already left PENDING before we got here
            # (callback fired, dispatch failed, or was abandoned by
            # an earlier timeout). Nothing to do.
            return

        fut = op.future
        if isinstance(fut, CallFuture):
            fut._mark_abandoned()
            if not fut.done():
                try:
                    fut.set_exception(
                        TimeoutError(
                            "LingoFuse async call abandoned after "
                            "timeout; the C-side request may still "
                            "be in flight, but its result will be "
                            "discarded."
                        )
                    )
                except concurrent.futures.InvalidStateError:
                    # Race: the callback resolved the future
                    # between our done() check and set_exception.
                    # The callback wins; drop our timeout.
                    pass

        self._schedule_release_after_grace(op)

    def _release_op(self, op: AsyncOp) -> None:
        """
        Drop the bridge's reference to the op. Idempotent: a second
        call for the same op is a no-op.
        """
        with self._handles_lock:
            key = op._key
            if key is None:
                return
            if key not in self._handles:
                return
            self._handles.pop(key, None)
            self._release_count += 1

    # ------------------------------------------------------------------
    # Diagnostics
    # ------------------------------------------------------------------

    def stats(self) -> dict:
        """
        Return a snapshot of the bridge's current state.

        Safe to call from any thread. The returned dict is a plain
        copy; mutating it does not affect the bridge.
        """
        with self._handles_lock:
            handles = list(self._handles.values())
            released_total = self._release_count

        counts = {
            AsyncOp.STATE_PENDING: 0,
            AsyncOp.STATE_FIRED: 0,
            AsyncOp.STATE_ABANDONED: 0,
            AsyncOp.STATE_NOT_QUEUED: 0,
        }
        for h in handles:
            state = h.state
            counts[state] = counts.get(state, 0) + 1

        return {
            "total": len(handles),
            "pending": counts[AsyncOp.STATE_PENDING],
            "fired": counts[AsyncOp.STATE_FIRED],
            "abandoned": counts[AsyncOp.STATE_ABANDONED],
            "not_queued": counts[AsyncOp.STATE_NOT_QUEUED],
            "released_total": released_total,
            "grace_seconds": self.grace_seconds,
            "period_seconds": self.period_seconds,
        }

    # ------------------------------------------------------------------
    # Shutdown
    # ------------------------------------------------------------------

    def shutdown(self) -> None:
        """
        Release every tracked op and stop the reclamation thread.

        Safe to call multiple times. After shutdown, the bridge is
        unusable; obtain a fresh instance via :meth:`instance`.
        """
        with self._cv:
            if self._shutdown:
                return
            self._shutdown = True
            self._cv.notify_all()

        # Drain the queues. Any op still in flight on the C side
        # will have its ctypes callback dropped when the op object
        # is garbage-collected. This is a best-effort cleanup
        # intended for process teardown.
        with self._cv:
            self._release_queue.clear()
            self._timeout_queue.clear()

        with self._handles_lock:
            self._handles.clear()

        self._thread.join(timeout=2.0)


# ======================================================================
# Factory helpers
# ======================================================================

def _create_async_op(
    deliver_fn: Callable[[Any, Optional[Exception]], None],
    deserialize: Callable[[Any], Any],
    future: Optional[CallFuture] = None,
) -> AsyncOp:
    """
    Create a ctypes callback and wrap it in an :class:`AsyncOp`.

    The ctypes callback:

      * deserializes the raw result handle,
      * invokes ``deliver_fn(result, error)`` exactly once,
      * delegates state transitions to ``op._invoke_from_c``.

    The op is registered with the bridge BEFORE it is returned, so
    that the callback is never live on the C side without a
    corresponding bridge entry.
    """
    # A single-element list acts as a mutable cell so that the
    # callback closure can reach the op, which does not exist yet
    # at the moment the closure is defined.
    op_cell: list = [None]

    def _c_callback(raw_data: Any, raw_result: Any) -> None:
        op: AsyncOp = op_cell[0]
        if op is None:
            # Defensive guard; should not happen because the
            # callback is only installed after op_cell[0] is set.
            return

        result: Any = None
        error: Optional[Exception] = None

        if raw_result:
            try:
                result = deserialize(raw_result)
            except Exception as exc:
                error = exc

        op._invoke_from_c(result, error)

    c_callback = LFAsyncCallOnResult(_c_callback)
    op = AsyncOp(
        deliver_fn=deliver_fn,
        c_callback=c_callback,
        future=future,
    )
    op_cell[0] = op
    AsyncBridge.instance().register(op)
    return op


def make_legacy_op(
    on_result: Callable[[Any, Optional[Exception], Any], None],
    user_data: Any,
    deserialize: Callable[[Any], Any],
) -> AsyncOp:
    """
    Build an :class:`AsyncOp` for the traditional "user provides a
    callback" style.

    The user's callback is invoked as::

        on_result(result, error, user_data)

    on the C worker thread. It MUST NOT block, and MUST NOT call
    any synchronous LingoFuse function.

    Exceptions raised by the user's callback are caught and logged;
    they never escape into the C stack.
    """
    def _deliver(result: Any, error: Optional[Exception]) -> None:
        try:
            on_result(result, error, user_data)
        except Exception:
            _log.exception("User async on_result callback raised")

    return _create_async_op(_deliver, deserialize)


def make_future_op(
    deserialize: Callable[[Any], Any],
) -> Tuple[AsyncOp, CallFuture]:
    """
    Build an :class:`AsyncOp` + :class:`CallFuture` pair.

    No timeout is armed here; call :meth:`AsyncBridge.schedule_timeout`
    after successful dispatch (the :func:`run_async_with_future`
    helper does this automatically).

    Returns ``(op, future)``.
    """
    future = CallFuture()

    def _deliver(result: Any, error: Optional[Exception]) -> None:
        if future.done():
            return
        try:
            if error is not None:
                future.set_exception(error)
            else:
                future.set_result(result)
        except concurrent.futures.InvalidStateError:
            # Race: someone else resolved the future concurrently.
            # The winner stands; drop our attempt.
            pass

    op = _create_async_op(_deliver, deserialize, future=future)
    return op, future


def run_async_with_future(
    issue_fn: Callable[[Any], int],
    deserialize: Callable[[Any], Any],
    timeout_ms: Optional[int] = None,
) -> CallFuture:
    """
    One-stop helper: build op+future, issue the C request, arm the
    timeout on success, and return the future.

    Parameters
    ----------
    issue_fn:
        A callable that takes the ctypes callback object and issues
        the C-side request. Typically a small closure around
        ``LF_Async_Call`` (or one of its UID_* / P2PName_* variants)
        that returns 1 on successful dispatch, 0 on failure.
    deserialize:
        A callable that converts the raw result handle (a
        ``c_void_p``) into a Python object.
    timeout_ms:
        Optional Python-side timeout. If the callback does not fire
        within this many milliseconds, the returned future is
        resolved with :class:`~lingofuse.errors.TimeoutError` and
        its ``abandoned`` flag becomes True.

    Returns
    -------
    CallFuture
        Always returns a future, even on dispatch failure. In that
        case the future is resolved with a
        :class:`~lingofuse.errors.LingoFuseError`.

    Notes
    -----
    The ``issue_fn`` is called synchronously. If it raises, the
    exception propagates to the caller AFTER the op is marked as
    not-queued (so no leak occurs).
    """
    op, future = make_future_op(deserialize)

    try:
        ret = issue_fn(op.c_callback)
    except BaseException:
        # The C request was not issued. Release the op and re-raise.
        op.mark_not_queued()
        raise

    if ret != 1:
        # Dispatch failed; the callback will never fire.
        op.mark_not_queued()
        if not future.done():
            try:
                future.set_exception(
                    LingoFuseError(
                        f"async request was not queued "
                        f"(dispatch returned {ret!r})"
                    )
                )
            except concurrent.futures.InvalidStateError:
                pass
        return future

    if timeout_ms is not None and timeout_ms > 0:
        AsyncBridge.instance().schedule_timeout(op, timeout_ms)

    return future


# ======================================================================
# asyncio bridge
# ======================================================================

async def await_future(future: concurrent.futures.Future) -> Any:
    """
    Await a :class:`concurrent.futures.Future` from within an
    asyncio coroutine.

    The timeout, if any, should already be encoded in the future
    itself (via ``run_async_with_future(timeout_ms=...)``). This
    function deliberately does NOT apply an additional timeout,
    because cancelling the asyncio wrapper does not cancel the
    underlying C request and would leave the two in disagreement.

    If the future resolves with an exception, this function raises
    it.

    Example::

        future = target.call_future("api", payload, timeout_ms=5000)
        result = await await_future(future)
    """
    return await asyncio.wrap_future(future)


# ======================================================================
# Public exports
# ======================================================================

__all__ = [
    "AsyncBridge",
    "AsyncOp",
    "CallFuture",
    "make_legacy_op",
    "make_future_op",
    "run_async_with_future",
    "await_future",
]