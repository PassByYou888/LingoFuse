# -*- coding: utf-8 -*-
"""
Unit tests for lingofuse.async_support.

Coverage
--------

* CallFuture: the ``abandoned`` flag and its thread-safe read.
* AsyncOp: the PENDING -> FIRED | ABANDONED | NOT_QUEUED state
  machine, including idempotence of every transition and the
  "late callback after timeout drops the result" rule.
* AsyncBridge: registration, release scheduling, timeout
  processing, and the reclamation loop.
* make_future_op / make_legacy_op: factory behaviour, including
  delivery of results and errors to the caller's callback.
* run_async_with_future: the one-stop helper, covering success,
  dispatch failure, issue_fn exceptions, and the timeout path.
* await_future: the asyncio bridge.

These tests exercise PURE PYTHON behaviour. They do NOT call any
LingoFuse C function: every async operation is driven by manually
invoking the state-machine transition that the real ctypes callback
would otherwise invoke. The only C-side dependency is that
``lingofuse._lf_native`` must be importable, because
``LFAsyncCallOnResult`` is used to construct the ctypes callback
object inside each op. That import-time load is the same
prerequisite that every other test in this suite has.

Isolation
---------

Each test class replaces the process-wide ``AsyncBridge`` singleton
in ``setUp`` and shuts it down in ``tearDown``. This guarantees that
no operation from one test can influence the counters or the
reclamation queues observed by another.

Timing
------

The default grace period (60 s) and reclamation period (1 s) are too
slow for unit tests. Every test class that exercises timeouts or the
reclamation loop shrinks both values at ``setUp`` time. Waits use
generous upper bounds (typically 10x the expected delay) so that a
slow CI machine does not produce flaky failures.

All status output is in English.
"""

import asyncio
import logging
import os
import sys
import threading
import time
import unittest

# Ensure the parent directory is importable when running from the
# repository root, matching the convention used by
# test_lingofuse.py.
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from lingofuse.async_support import (
    AsyncBridge,
    AsyncOp,
    CallFuture,
    await_future,
    make_future_op,
    make_legacy_op,
    run_async_with_future,
)
from lingofuse.errors import LingoFuseError
from lingofuse.errors import TimeoutError as LfTimeoutError


# ======================================================================
# Logging
# ----------------------------------------------------------------------
# Several tests intentionally trigger log emissions from the async
# subsystem (for example, "delivery callback raised"). We do not
# want those to pollute the test output, so the module logger is
# raised to CRITICAL for the duration of the suite. The behavior
# under test is the state transition, not the log line.
# ======================================================================

logging.getLogger("lingofuse.async_support").setLevel(logging.CRITICAL)


# ======================================================================
# Helpers
# ======================================================================

def _identity(x):
    """Trivial deserializer: pass the raw handle through unchanged."""
    return x


class _BridgeTestBase(unittest.TestCase):
    """
    Base class that isolates the AsyncBridge singleton per test.

    Every concrete test class that exercises the bridge inherits
    from this so that the process never carries state from one test
    into the next. The singleton is replaced in setUp and shut down
    in tearDown.
    """

    def setUp(self):
        AsyncBridge.shutdown_instance()
        self.bridge = AsyncBridge.instance()
        # Speed up the reclamation loop. The reclamation thread
        # reads these attributes on each iteration, so assigning
        # them here takes effect on the next wait() timeout.
        self.bridge.period_seconds = 0.02
        self.bridge.grace_seconds = 0.2

    def tearDown(self):
        AsyncBridge.shutdown_instance()

    def _wait_for_total(self, expected, timeout=2.0):
        """
        Wait for the bridge's op count to reach ``expected``, or
        raise AssertionError with a diagnostic after ``timeout``
        seconds.
        """
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            if self.bridge.stats()["total"] == expected:
                return
            time.sleep(0.02)
        self.fail(
            f"bridge.stats()['total'] never reached {expected}; "
            f"observed {self.bridge.stats()}"
        )


# ======================================================================
# CallFuture
# ======================================================================

class TestCallFuture(unittest.TestCase):
    """CallFuture: the ``abandoned`` flag and its thread-safe read."""

    def test_initial_flag_is_false(self):
        f = CallFuture()
        self.assertFalse(f.abandoned)

    def test_mark_abandoned_sets_flag(self):
        f = CallFuture()
        f._mark_abandoned()
        self.assertTrue(f.abandoned)

    def test_mark_abandoned_is_idempotent(self):
        f = CallFuture()
        f._mark_abandoned()
        f._mark_abandoned()
        f._mark_abandoned()
        self.assertTrue(f.abandoned)

    def test_thread_safe_read(self):
        """
        Concurrent readers must observe a valid bool at every point,
        with no torn read. The exact number of each value is not
        asserted; we only require that reads do not raise, that every
        observed value is a bool, and that after the write completes
        some reads see the new value.
        """
        f = CallFuture()
        observed = []
        stop = threading.Event()

        def _reader():
            while not stop.is_set():
                try:
                    observed.append(f.abandoned)
                except Exception as exc:
                    observed.append(exc)

        readers = [threading.Thread(target=_reader) for _ in range(4)]
        for t in readers:
            t.start()

        try:
            time.sleep(0.02)
            f._mark_abandoned()
            time.sleep(0.05)
        finally:
            stop.set()
            for t in readers:
                t.join(timeout=1.0)

        # No read raised an exception.
        self.assertTrue(
            all(isinstance(x, bool) for x in observed),
            f"non-bool value observed: {observed!r}",
        )
        # Some reads saw the post-write value.
        self.assertTrue(any(observed))


# ======================================================================
# AsyncOp state machine
# ======================================================================

class TestAsyncOpStateMachine(_BridgeTestBase):
    """
    AsyncOp: state transitions and their idempotence.

    Every transition is exercised by calling the internal method
    directly. This is the same method the real ctypes callback
    would invoke; calling it directly keeps the test free of any
    dependency on the C side.
    """

    def _make_op(self):
        """
        Create a pending legacy op whose delivery records every call.

        Returns (op, delivered_list). Each delivery appends a tuple
        ``(result, error, user_data)`` to the list.
        """
        delivered = []
        op = make_legacy_op(
            on_result=lambda r, e, u: delivered.append((r, e, u)),
            user_data="ctx",
            deserialize=_identity,
        )
        return op, delivered

    # ---- Initial state ----

    def test_initial_state_is_pending(self):
        op, _ = self._make_op()
        self.assertEqual(op.state, AsyncOp.STATE_PENDING)

    # ---- mark_not_queued ----

    def test_mark_not_queued_changes_state(self):
        op, _ = self._make_op()
        op.mark_not_queued()
        self.assertEqual(op.state, AsyncOp.STATE_NOT_QUEUED)

    def test_mark_not_queued_is_idempotent(self):
        op, _ = self._make_op()
        op.mark_not_queued()
        op.mark_not_queued()
        self.assertEqual(op.state, AsyncOp.STATE_NOT_QUEUED)

    # ---- _abandon ----

    def test_abandon_from_pending_returns_true(self):
        op, _ = self._make_op()
        self.assertTrue(op._abandon())
        self.assertEqual(op.state, AsyncOp.STATE_ABANDONED)

    def test_abandon_from_fired_returns_false(self):
        op, _ = self._make_op()
        op._invoke_from_c("value", None)
        self.assertFalse(op._abandon())
        self.assertEqual(op.state, AsyncOp.STATE_FIRED)

    def test_abandon_from_abandoned_returns_false(self):
        op, _ = self._make_op()
        op._abandon()
        self.assertFalse(op._abandon())

    # ---- _invoke_from_c ----

    def test_invoke_from_pending_delivers_result(self):
        op, delivered = self._make_op()
        op._invoke_from_c("hello", None)
        self.assertEqual(delivered, [("hello", None, "ctx")])
        self.assertEqual(op.state, AsyncOp.STATE_FIRED)

    def test_invoke_from_pending_delivers_error(self):
        op, delivered = self._make_op()
        err = RuntimeError("boom")
        op._invoke_from_c(None, err)
        self.assertEqual(delivered, [(None, err, "ctx")])
        self.assertEqual(op.state, AsyncOp.STATE_FIRED)

    def test_invoke_from_abandoned_drops_result(self):
        """
        A callback that arrives after the timeout must NOT deliver
        its result. The op transitions to FIRED so it can be
        released promptly, but the delivery function is not called.
        """
        op, delivered = self._make_op()
        op._abandon()
        op._invoke_from_c("late", None)
        self.assertEqual(delivered, [])
        self.assertEqual(op.state, AsyncOp.STATE_FIRED)

    def test_invoke_twice_is_noop(self):
        op, delivered = self._make_op()
        op._invoke_from_c("first", None)
        op._invoke_from_c("second", None)
        self.assertEqual(delivered, [("first", None, "ctx")])

    def test_invoke_after_not_queued_is_noop(self):
        op, delivered = self._make_op()
        op.mark_not_queued()
        op._invoke_from_c("never", None)
        self.assertEqual(delivered, [])
        self.assertEqual(op.state, AsyncOp.STATE_NOT_QUEUED)

    def test_delivery_exception_is_swallowed(self):
        """
        If the user's callback raises, the exception must not escape
        into the C stack. The AsyncOp wrapper catches it and logs.
        """
        def _bad_deliver(result, error, user_data):
            raise RuntimeError("intentional")

        op = make_legacy_op(
            on_result=_bad_deliver,
            user_data=None,
            deserialize=_identity,
        )
        # Must not raise.
        op._invoke_from_c("x", None)
        # The op transitioned to FIRED despite the exception.
        self.assertEqual(op.state, AsyncOp.STATE_FIRED)


# ======================================================================
# AsyncBridge registry and release
# ======================================================================

class TestAsyncBridgeRegistry(_BridgeTestBase):
    """Registration, release scheduling, and the stats snapshot."""

    def test_register_increments_total(self):
        initial = self.bridge.stats()
        op, _ = make_future_op(deserialize=_identity)
        after = self.bridge.stats()
        self.assertEqual(after["total"], initial["total"] + 1)
        self.assertEqual(after["pending"], initial["pending"] + 1)

    def test_release_op_removes_from_registry(self):
        op, _ = make_future_op(deserialize=_identity)
        self.assertEqual(self.bridge.stats()["total"], 1)
        self.bridge._release_op(op)
        self.assertEqual(self.bridge.stats()["total"], 0)

    def test_release_op_is_idempotent(self):
        op, _ = make_future_op(deserialize=_identity)
        self.bridge._release_op(op)
        self.bridge._release_op(op)
        self.bridge._release_op(op)
        self.assertEqual(self.bridge.stats()["total"], 0)

    def test_stats_pending_goes_to_zero_after_callback(self):
        """
        Once the callback fires, the op leaves PENDING. It may
        briefly be observed as FIRED before the reclamation thread
        releases it, but it must never remain PENDING.
        """
        op, _ = make_future_op(deserialize=_identity)
        op._invoke_from_c("x", None)
        self.assertEqual(self.bridge.stats()["pending"], 0)


# ======================================================================
# Timeout and abandonment
# ======================================================================

class TestAsyncBridgeTimeout(_BridgeTestBase):
    """The Python-side timeout path."""

    def test_timeout_marks_future_abandoned(self):
        def _issue(cb):
            return 1  # successfully queued, but never fires

        future = run_async_with_future(
            issue_fn=_issue,
            deserialize=_identity,
            timeout_ms=50,
        )

        with self.assertRaises(LfTimeoutError):
            future.result(timeout=2.0)

        self.assertTrue(future.abandoned)

    def test_timeout_keeps_op_in_registry_for_grace_period(self):
        """
        After a timeout, the op must remain tracked for the grace
        period so that a late callback finds a valid Python object.
        """
        def _issue(cb):
            return 1

        future = run_async_with_future(
            issue_fn=_issue,
            deserialize=_identity,
            timeout_ms=50,
        )
        with self.assertRaises(LfTimeoutError):
            future.result(timeout=2.0)

        s = self.bridge.stats()
        self.assertGreaterEqual(s["abandoned"], 1)
        self.assertGreaterEqual(s["total"], 1)

    def test_late_callback_after_timeout_is_dropped(self):
        """
        A callback that arrives after the timeout must not overwrite
        the timeout error on the future, and its result must be
        dropped.
        """
        def _issue(cb):
            return 1

        future = run_async_with_future(
            issue_fn=_issue,
            deserialize=_identity,
            timeout_ms=50,
        )
        with self.assertRaises(LfTimeoutError):
            future.result(timeout=2.0)
        self.assertTrue(future.abandoned)

        # Find the op in the registry and simulate a late callback.
        with self.bridge._handles_lock:
            ops = list(self.bridge._handles.values())
        self.assertEqual(len(ops), 1)
        op = ops[0]
        self.assertEqual(op.state, AsyncOp.STATE_ABANDONED)

        # The late callback must not raise, and must transition the
        # op to FIRED so it can be released promptly.
        op._invoke_from_c("late result", None)
        self.assertEqual(op.state, AsyncOp.STATE_FIRED)

        # The future still carries the TimeoutError.
        self.assertTrue(future.done())
        with self.assertRaises(LfTimeoutError):
            future.result()

    def test_zero_timeout_disables_timeout(self):
        def _issue(cb):
            return 1

        future = run_async_with_future(
            issue_fn=_issue,
            deserialize=_identity,
            timeout_ms=0,
        )
        self.assertFalse(future.done())
        self.assertFalse(future.abandoned)

    def test_none_timeout_disables_timeout(self):
        def _issue(cb):
            return 1

        future = run_async_with_future(
            issue_fn=_issue,
            deserialize=_identity,
            timeout_ms=None,
        )
        self.assertFalse(future.done())
        self.assertFalse(future.abandoned)


# ======================================================================
# Factory helpers
# ======================================================================

class TestMakeOps(_BridgeTestBase):
    """make_future_op and make_legacy_op."""

    def test_make_future_op_returns_pair(self):
        op, future = make_future_op(deserialize=_identity)
        self.assertIsInstance(op, AsyncOp)
        self.assertIsInstance(future, CallFuture)
        self.assertIs(op.future, future)

    def test_make_legacy_op_returns_op_without_future(self):
        op = make_legacy_op(
            on_result=lambda r, e, u: None,
            user_data=None,
            deserialize=_identity,
        )
        self.assertIsInstance(op, AsyncOp)
        self.assertIsNone(op.future)

    def test_future_op_delivers_result(self):
        op, future = make_future_op(deserialize=_identity)
        op._invoke_from_c("value", None)
        self.assertEqual(future.result(timeout=1.0), "value")

    def test_future_op_delivers_error(self):
        op, future = make_future_op(deserialize=_identity)
        err = ValueError("bad")
        op._invoke_from_c(None, err)
        with self.assertRaises(ValueError):
            future.result(timeout=1.0)

    def test_legacy_op_delivers_user_callback(self):
        recorded = []

        def _on_result(result, error, user_data):
            recorded.append((result, error, user_data))

        op = make_legacy_op(
            on_result=_on_result,
            user_data="tag",
            deserialize=_identity,
        )
        op._invoke_from_c("x", None)
        self.assertEqual(recorded, [("x", None, "tag")])

    def test_legacy_op_swallows_user_exception(self):
        def _bad(result, error, user_data):
            raise RuntimeError("intentional")

        op = make_legacy_op(
            on_result=_bad,
            user_data=None,
            deserialize=_identity,
        )
        # Must not propagate.
        op._invoke_from_c("x", None)

    def test_ctypes_callback_forwards_to_state_machine(self):
        """
        The ctypes callback object installed by make_future_op must
        forward to the state machine when invoked. We call it
        directly (from Python, not from C) with a null raw_result;
        the state machine receives (None, None) and resolves the
        future with None.
        """
        op, future = make_future_op(deserialize=_identity)
        # c_void_p accepts None for NULL.
        op.c_callback(None, None)
        self.assertEqual(future.result(timeout=1.0), None)
        self.assertEqual(op.state, AsyncOp.STATE_FIRED)


# ======================================================================
# run_async_with_future
# ======================================================================

class TestRunAsyncWithFuture(_BridgeTestBase):
    """The one-stop helper: every exit path."""

    def test_success_path_returns_pending_future(self):
        def _issue(cb):
            return 1

        future = run_async_with_future(
            issue_fn=_issue,
            deserialize=_identity,
            timeout_ms=1000,
        )
        self.assertIsInstance(future, CallFuture)
        self.assertFalse(future.done())

    def test_dispatch_failure_resolves_future_with_error(self):
        def _issue(cb):
            return 0  # rejected before dispatch

        future = run_async_with_future(
            issue_fn=_issue,
            deserialize=_identity,
            timeout_ms=1000,
        )
        # The future is resolved immediately, without waiting for the
        # timeout.
        self.assertTrue(future.done())
        with self.assertRaises(LingoFuseError):
            future.result(timeout=1.0)
        # No op remains tracked once the reclamation thread has run.
        self._wait_for_total(0)

    def test_issue_fn_exception_propagates(self):
        def _issue(cb):
            raise RuntimeError("dispatch broke")

        with self.assertRaises(RuntimeError):
            run_async_with_future(
                issue_fn=_issue,
                deserialize=_identity,
                timeout_ms=1000,
            )
        # Even on an exception, the op must be released so that the
        # bridge does not leak.
        self._wait_for_total(0)

    def test_negative_return_value_is_dispatch_failure(self):
        """
        Any return value other than 1 is a dispatch failure. The
        C ABI documents 1 as success and 0 as failure, but we are
        defensive about unforeseen return values.
        """
        def _issue(cb):
            return -1

        future = run_async_with_future(
            issue_fn=_issue,
            deserialize=_identity,
            timeout_ms=1000,
        )
        with self.assertRaises(LingoFuseError):
            future.result(timeout=1.0)
        self._wait_for_total(0)

    def test_large_return_value_is_dispatch_failure(self):
        """
        Any non-1 return value, however large, is a dispatch failure.
        """
        def _issue(cb):
            return 999

        future = run_async_with_future(
            issue_fn=_issue,
            deserialize=_identity,
            timeout_ms=1000,
        )
        with self.assertRaises(LingoFuseError):
            future.result(timeout=1.0)
        self._wait_for_total(0)


# ======================================================================
# await_future (asyncio bridge)
# ======================================================================

class TestAwaitFuture(_BridgeTestBase):
    """await_future resolves CallFuture objects from a coroutine."""

    def test_await_ready_future(self):
        op, future = make_future_op(deserialize=_identity)
        op._invoke_from_c("ready", None)

        async def _run():
            return await await_future(future)

        result = asyncio.run(_run())
        self.assertEqual(result, "ready")

    def test_await_pending_future_resolved_from_thread(self):
        op, future = make_future_op(deserialize=_identity)

        def _resolve_later():
            time.sleep(0.05)
            op._invoke_from_c("from thread", None)

        t = threading.Thread(target=_resolve_later)
        t.start()

        async def _run():
            return await await_future(future)

        try:
            result = asyncio.run(_run())
        finally:
            t.join(timeout=2.0)

        self.assertEqual(result, "from thread")

    def test_await_future_with_error_propagates(self):
        op, future = make_future_op(deserialize=_identity)
        op._invoke_from_c(None, RuntimeError("async boom"))

        async def _run():
            return await await_future(future)

        with self.assertRaises(RuntimeError):
            asyncio.run(_run())

    def test_await_future_with_timeout_error_propagates(self):
        def _issue(cb):
            return 1

        future = run_async_with_future(
            issue_fn=_issue,
            deserialize=_identity,
            timeout_ms=30,
        )

        async def _run():
            return await await_future(future)

        with self.assertRaises(LfTimeoutError):
            asyncio.run(_run())
        self.assertTrue(future.abandoned)


# ======================================================================
# Shutdown behaviour
# ======================================================================

class TestShutdown(unittest.TestCase):
    """
    shutdown() and shutdown_instance().

    These tests do not inherit from _BridgeTestBase because they
    exercise the singleton lifecycle itself.
    """

    def tearDown(self):
        # Ensure a clean slate for the next test class regardless of
        # which branch ran.
        AsyncBridge.shutdown_instance()

    def test_shutdown_instance_clears_registry(self):
        AsyncBridge.shutdown_instance()
        bridge = AsyncBridge.instance()
        make_future_op(deserialize=_identity)
        make_future_op(deserialize=_identity)
        self.assertEqual(bridge.stats()["total"], 2)

        AsyncBridge.shutdown_instance()
        # The next instance is a fresh, empty bridge.
        fresh = AsyncBridge.instance()
        self.assertEqual(fresh.stats()["total"], 0)

    def test_shutdown_method_is_idempotent(self):
        AsyncBridge.shutdown_instance()
        bridge = AsyncBridge.instance()
        bridge.shutdown()
        bridge.shutdown()
        bridge.shutdown()
        # No exception, no hang. The thread was joined on the first
        # call and subsequent calls are no-ops.

    def test_shutdown_instance_without_prior_instance(self):
        # Ensure no instance exists.
        AsyncBridge.shutdown_instance()
        # Calling again must not raise.
        AsyncBridge.shutdown_instance()

    def test_new_instance_after_shutdown_starts_empty(self):
        AsyncBridge.shutdown_instance()
        first = AsyncBridge.instance()
        make_future_op(deserialize=_identity)
        self.assertEqual(first.stats()["total"], 1)

        AsyncBridge.shutdown_instance()
        second = AsyncBridge.instance()
        self.assertIsNot(first, second)
        self.assertEqual(second.stats()["total"], 0)


# ======================================================================
# Integration
# ======================================================================

class TestIntegration(_BridgeTestBase):
    """
    Multi-op scenarios that exercise the reclamation loop end-to-end.
    """

    def test_multiple_ops_are_independent(self):
        ops = []
        futures = []
        for i in range(5):
            op, future = make_future_op(deserialize=_identity)
            ops.append(op)
            futures.append(future)

        for i, op in enumerate(ops):
            op._invoke_from_c(f"result-{i}", None)

        for i, future in enumerate(futures):
            self.assertEqual(
                future.result(timeout=1.0), f"result-{i}"
            )

    def test_release_is_eventually_processed(self):
        """
        After a callback fires, the reclamation thread must release
        the op. We wait a bounded time for this to happen rather than
        asserting on an exact tick, so the test is not flaky on a
        slow CI machine.
        """
        op, _ = make_future_op(deserialize=_identity)
        op._invoke_from_c("x", None)
        self._wait_for_total(0)

    def test_abandoned_op_released_after_grace(self):
        """
        An op that timed out must be released after the grace period
        has elapsed, even if no late callback ever arrives.
        """
        def _issue(cb):
            return 1

        future = run_async_with_future(
            issue_fn=_issue,
            deserialize=_identity,
            timeout_ms=30,
        )
        with self.assertRaises(LfTimeoutError):
            future.result(timeout=2.0)

        # grace is 0.2s in setUp; wait up to 2s for release.
        self._wait_for_total(0)

    def test_mixed_success_and_timeout(self):
        """
        A batch where some ops succeed and some time out must keep
        the state machine consistent: successes resolve with their
        result, timeouts resolve with TimeoutError and abandon.
        """
        # Two ops that will be resolved manually.
        op_ok1, fut_ok1 = make_future_op(deserialize=_identity)
        op_ok2, fut_ok2 = make_future_op(deserialize=_identity)

        # One op that will be left to time out.
        def _issue(cb):
            return 1

        fut_to = run_async_with_future(
            issue_fn=_issue,
            deserialize=_identity,
            timeout_ms=50,
        )

        # Resolve the two manual ops.
        op_ok1._invoke_from_c("a", None)
        op_ok2._invoke_from_c("b", None)

        self.assertEqual(fut_ok1.result(timeout=1.0), "a")
        self.assertEqual(fut_ok2.result(timeout=1.0), "b")

        with self.assertRaises(LfTimeoutError):
            fut_to.result(timeout=2.0)
        self.assertTrue(fut_to.abandoned)

    def test_op_reuse_after_delivery_does_not_double_release(self):
        """
        Once an op is FIRED and released, a second _invoke_from_c
        must be a no-op: the delivery is not repeated and no
        KeyError arises from a double release attempt.
        """
        op, future = make_future_op(deserialize=_identity)
        op._invoke_from_c("x", None)
        self.assertEqual(future.result(timeout=1.0), "x")
        self._wait_for_total(0)

        # Second invocation must be a no-op.
        op._invoke_from_c("y", None)
        self.assertEqual(op.state, AsyncOp.STATE_FIRED)
        # The future's result is unchanged.
        self.assertEqual(future.result(), "x")


# ======================================================================
# Entry point
# ======================================================================

if __name__ == "__main__":
    unittest.main()