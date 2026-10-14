# frozen_string_literal: true
#
# test_async_support.rb — Unit tests for LingoFuse::AsyncSupport.
#
# ============================================================================
# COVERAGE
# ============================================================================
# This file exercises the async subsystem in three layers:
#
#   1. TestCallFuture
#        The Future primitive itself. No C extension required: the
#        Future is pure Ruby, so these tests run on any machine.
#
#   2. TestRunAsyncWithFuture
#        The factory helper. Uses a fake issue_fn to exercise the
#        dispatch-failure path without touching the network.
#
#   3. TestAsyncBridge
#        The singleton manager: registration, timeout abandonment,
#        grace-period release, and shutdown.
#
#   4. TestTrampolineIntegration
#        End-to-end: launches the Ruby dispatcher thread and triggers
#        the C-extension's trampoline_async_call from a native
#        pthread. This is the only class in the file that exercises
#        the C side of the async contract.
#
# ============================================================================
# TESTING NOTES
# ============================================================================
# * The bridge's reclaim thread uses a period and grace that can be
#   shortened per-instance. Every test class that exercises the reclaim
#   loop shrinks both to milliseconds so the tests finish quickly.
#
# * Every test class calls AsyncBridge.shutdown_instance in both setup
#   and teardown. This guarantees isolation: no op from one test can
#   influence the counters observed by another.
#
# * Waits use generous upper bounds (10x the expected delay) so that a
#   slow CI machine does not produce flaky failures.
#
# * All output is in English, matching the rest of the test suite.
# ============================================================================

require 'minitest/autorun'
require 'thread'

_lib_dir = File.expand_path('../lib', __dir__)
$LOAD_PATH.unshift(_lib_dir) unless $LOAD_PATH.include?(_lib_dir)

begin
  require 'lingofuse'
rescue StandardError, LoadError => e
  warn "Failed to load LingoFuse: #{e.class}: #{e.message}"
end

class TestCallFuture < Minitest::Test
  # ------------------------------------------------------------------
  # The Future primitive has no dependencies. These tests run whether
  # or not the C extension is available.
  # ------------------------------------------------------------------

  def setup
    skip 'LingoFuse::CallFuture not loaded' unless defined?(LingoFuse::CallFuture)
  end

  # ==================================================================
  # Initial state
  # ==================================================================

  def test_initial_state
    f = LingoFuse::CallFuture.new
    refute f.done?
    refute f.abandoned?
  end

  # ==================================================================
  # fulfill / reject
  # ==================================================================

  def test_fulfill_resolves_value
    f = LingoFuse::CallFuture.new
    f.fulfill(42)
    assert f.done?
    assert_equal 42, f.value(timeout_ms: 100)
  end

  def test_reject_raises_in_value
    f = LingoFuse::CallFuture.new
    err = RuntimeError.new('boom')
    f.reject(err)
    assert f.done?

    raised = assert_raises(RuntimeError) do
      f.value(timeout_ms: 100)
    end
    assert_same err, raised
  end

  def test_fulfill_after_fulfill_is_noop
    f = LingoFuse::CallFuture.new
    f.fulfill(:first)
    f.fulfill(:second)
    assert_equal :first, f.value(timeout_ms: 100)
  end

  def test_reject_after_fulfill_is_noop
    f = LingoFuse::CallFuture.new
    f.fulfill(:ok)
    f.reject(RuntimeError.new('late'))
    assert_equal :ok, f.value(timeout_ms: 100)
  end

  def test_fulfill_after_reject_is_noop
    f = LingoFuse::CallFuture.new
    err = RuntimeError.new('first')
    f.reject(err)
    f.fulfill(:late)

    raised = assert_raises(RuntimeError) { f.value(timeout_ms: 100) }
    assert_same err, raised
  end

  # ==================================================================
  # Abandoned flag
  # ==================================================================

  def test_mark_abandoned_sets_flag
    f = LingoFuse::CallFuture.new
    refute f.abandoned?
    f.mark_abandoned!
    assert f.abandoned?
  end

  def test_mark_abandoned_is_idempotent
    f = LingoFuse::CallFuture.new
    f.mark_abandoned!
    f.mark_abandoned!
    f.mark_abandoned!
    assert f.abandoned?
  end

  # ==================================================================
  # Timeout
  # ==================================================================

  def test_timeout_raises_and_marks_abandoned
    f = LingoFuse::CallFuture.new
    assert_raises(LingoFuse::TimeoutError) do
      f.value(timeout_ms: 30)
    end
    assert f.abandoned?
    refute f.done?
  end

  def test_value_arrives_just_before_timeout
    f = LingoFuse::CallFuture.new
    Thread.new do
      sleep 0.02
      f.fulfill(:just_in_time)
    end
    assert_equal :just_in_time, f.value(timeout_ms: 500)
    refute f.abandoned?
  end

  def test_timeout_then_late_fulfill_does_not_crash
    f = LingoFuse::CallFuture.new
    assert_raises(LingoFuse::TimeoutError) do
      f.value(timeout_ms: 20)
    end
    assert f.abandoned?

    # A late callback must not raise. It may resolve the future, but
    # the abandoned flag stays set.
    f.fulfill(:late)
    assert f.done?
    assert f.abandoned?
    assert_equal :late, f.value(timeout_ms: 100)
  end

  # ==================================================================
  # Concurrency
  # ==================================================================

  def test_multiple_waiters_all_observe_resolution
    f = LingoFuse::CallFuture.new
    results = Queue.new

    4.times do
      Thread.new do
        begin
          results << f.value(timeout_ms: 1000)
        rescue StandardError => e
          results << e
        end
      end
    end

    sleep 0.02
    f.fulfill(:shared)

    4.times do
      v = results.pop
      assert_equal :shared, v
    end
  end
end

# ======================================================================
# Helper: a bridge with test-friendly timings
# ======================================================================

module BridgeTestHelper
  # Return the current AsyncBridge after replacing any existing one
  # with a fresh instance that has short grace / period.
  def fresh_bridge(grace: 0.1, period: 0.02)
    LingoFuse::AsyncBridge.shutdown_instance
    bridge = LingoFuse::AsyncBridge.instance
    bridge.grace_seconds = grace
    bridge.period_seconds = period
    bridge
  end

  def shutdown_bridge
    LingoFuse::AsyncBridge.shutdown_instance
  rescue StandardError
    # ignored: teardown must not mask a test failure
  end

  # Poll `predicate` until it returns true or `timeout_s` elapses.
  # Returns the predicate's last value. Raises on timeout.
  def wait_until(timeout_s: 2.0, interval_s: 0.01)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout_s
    loop do
      return true if yield
      if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
        return false
      end
      sleep interval_s
    end
  end
end

# ======================================================================
# run_async_with_future
# ======================================================================

class TestRunAsyncWithFuture < Minitest::Test
  include BridgeTestHelper

  def setup
    skip 'LingoFuse::AsyncBridge not loaded' unless defined?(LingoFuse::AsyncBridge)
    skip 'lingofuse_ext not available' unless LingoFuse::NativeBridge.available?

    @bridge = fresh_bridge
  end

  def teardown
    shutdown_bridge
  end

  # ------------------------------------------------------------------
  # Dispatch failure
  # ------------------------------------------------------------------

  def test_dispatch_failure_resolves_future_with_error
    issue_fn = ->(_ref) { 0 }   # 0 = not dispatched

    future = LingoFuse::AsyncSupport.run_async_with_future(
      issue_fn: issue_fn,
      deserialize: ->(addr) { addr },
      timeout_ms: 1000
    )

    assert future.done?, 'dispatch failure must resolve the future immediately'

    raised = assert_raises(LingoFuse::Error) do
      future.value(timeout_ms: 100)
    end
    assert_match(/not queued/, raised.message)
  end

  def test_dispatch_failure_releases_op
    issue_fn = ->(_ref) { 0 }

    LingoFuse::AsyncSupport.run_async_with_future(
      issue_fn: issue_fn,
      deserialize: ->(addr) { addr },
      timeout_ms: 1000
    )

    # The reclaim thread should release the failed op within a couple
    # of periods. Wait up to 2 s to be robust on a slow CI.
    released = wait_until(timeout_s: 2.0) do
      @bridge.stats[:total].zero?
    end
    assert released, 'dispatch failure must not leak an op'
  end

  # ------------------------------------------------------------------
  # issue_fn raising
  # ------------------------------------------------------------------

  def test_issue_fn_raising_propagates_and_releases
    issue_fn = ->(_ref) { raise RuntimeError, 'dispatch broke' }

    assert_raises(RuntimeError) do
      LingoFuse::AsyncSupport.run_async_with_future(
        issue_fn: issue_fn,
        deserialize: ->(addr) { addr },
        timeout_ms: 1000
      )
    end

    released = wait_until(timeout_s: 2.0) do
      @bridge.stats[:total].zero?
    end
    assert released, 'a raised issue_fn must not leak an op'
  end

  # ------------------------------------------------------------------
  # Successful dispatch (no network)
  # ------------------------------------------------------------------

  def test_successful_dispatch_registers_op
    issue_fn = ->(_ref) { 1 }   # 1 = dispatched

    future = LingoFuse::AsyncSupport.run_async_with_future(
      issue_fn: issue_fn,
      deserialize: ->(addr) { addr },
      timeout_ms: 10_000
    )

    refute future.done?, 'a queued op must not be resolved immediately'

    # Give the bridge a moment to process any queue.
    sleep 0.05
    stats = @bridge.stats
    assert_equal 1, stats[:total], 'the op must be tracked'
    assert_equal 1, stats[:pending], 'the op must be PENDING'
  end

  # ------------------------------------------------------------------
  # Timeout path
  # ------------------------------------------------------------------

  def test_timeout_abandons_op_and_releases_after_grace
    issue_fn = ->(_ref) { 1 }

    future = LingoFuse::AsyncSupport.run_async_with_future(
      issue_fn: issue_fn,
      deserialize: ->(addr) { addr },
      timeout_ms: 30
    )

    assert_raises(LingoFuse::TimeoutError) do
      future.value(timeout_ms: 500)
    end
    assert future.abandoned?

    # The bridge's reclaim thread must mark the op ABANDONED and then
    # release it after the grace period.
    released = wait_until(timeout_s: 2.0) do
      @bridge.stats[:total].zero?
    end
    assert released, 'abandoned op must be released after grace'
  end

  # ------------------------------------------------------------------
  # Argument validation
  # ------------------------------------------------------------------

  def test_run_async_with_future_requires_issue_fn
    assert_raises(ArgumentError) do
      LingoFuse::AsyncSupport.run_async_with_future(
        issue_fn: 'not callable',
        timeout_ms: 100
      )
    end
  end

  def test_run_async_with_future_requires_block_or_nil_deserialize
    # Passing deserialize: nil is explicitly supported.
    issue_fn = ->(_ref) { 0 }
    future = LingoFuse::AsyncSupport.run_async_with_future(
      issue_fn: issue_fn,
      deserialize: nil,
      timeout_ms: 100
    )
    assert future.done?
  end
end

# ======================================================================
# AsyncBridge
# ======================================================================

class TestAsyncBridge < Minitest::Test
  include BridgeTestHelper

  def setup
    skip 'LingoFuse::AsyncBridge not loaded' unless defined?(LingoFuse::AsyncBridge)
    skip 'lingofuse_ext not available' unless LingoFuse::NativeBridge.available?

    @bridge = fresh_bridge
  end

  def teardown
    shutdown_bridge
  end

  # ------------------------------------------------------------------
  # Singleton
  # ------------------------------------------------------------------

  def test_instance_returns_same_object
    a = LingoFuse::AsyncBridge.instance
    b = LingoFuse::AsyncBridge.instance
    assert_same a, b
  end

  def test_shutdown_instance_produces_new_object
    a = LingoFuse::AsyncBridge.instance
    LingoFuse::AsyncBridge.shutdown_instance
    b = LingoFuse::AsyncBridge.instance
    refute_same a, b
  end

  def test_shutdown_instance_is_idempotent
    LingoFuse::AsyncBridge.shutdown_instance
    LingoFuse::AsyncBridge.shutdown_instance
    LingoFuse::AsyncBridge.shutdown_instance
  end

  # ------------------------------------------------------------------
  # Stats shape
  # ------------------------------------------------------------------

  def test_stats_shape
    stats = @bridge.stats
    %i[total pending fired abandoned not_queued released_total
       grace_seconds period_seconds].each do |key|
      assert stats.key?(key), "stats must contain #{key.inspect}"
    end
    assert_equal 0, stats[:total]
  end

  # ------------------------------------------------------------------
  # Registry cleanup after shutdown
  # ------------------------------------------------------------------

  def test_shutdown_clears_registry
    # Register an op that will never fire.
    issue_fn = ->(_ref) { 1 }
    LingoFuse::AsyncSupport.run_async_with_future(
      issue_fn: issue_fn,
      deserialize: ->(addr) { addr },
      timeout_ms: 10_000
    )
    sleep 0.05
    refute_equal 0, LingoFuse::AsyncBridge.instance.stats[:total]

    LingoFuse::AsyncBridge.shutdown_instance

    fresh = LingoFuse::AsyncBridge.instance
    fresh.grace_seconds = 0.1
    fresh.period_seconds = 0.02
    assert_equal 0, fresh.stats[:total]
  end
end

# ======================================================================
# Trampoline integration (C extension)
# ======================================================================

class TestTrampolineIntegration < Minitest::Test
  include BridgeTestHelper

  # ------------------------------------------------------------------
  # Dispatcher thread: one per test class.
  #
  # The C extension's trampoline_async_call enqueues a CallbackItem and
  # blocks the native worker thread until the Ruby dispatcher dequeues
  # it and calls mark_done. Without a running dispatcher, the
  # trampoline would deadlock.
  # ------------------------------------------------------------------

  @dispatcher = nil
  @dispatcher_mutex = Mutex.new

  class << self
    attr_accessor :dispatcher, :dispatcher_mutex

    def ensure_dispatcher!
      dispatcher_mutex.synchronize do
        return if dispatcher&.alive?
        self.dispatcher = Thread.new do
          loop do
            LingoFuse::NativeBridge.wait_for_work(100)
            LingoFuse::NativeBridge.process_all
          rescue StandardError
            # keep looping
          end
        end
        if dispatcher.respond_to?(:name=)
          dispatcher.name = 'lingofuse-test-dispatcher'
        end
        sleep 0.05
      end
    end
  end

  def setup
    skip 'lingofuse_ext not available' unless LingoFuse::NativeBridge.available?
    skip 'async trampoline not exposed' unless LingoFuse::NativeBridge.respond_to?(:async_call_trampoline_addr)

    @bridge = fresh_bridge
    self.class.ensure_dispatcher!
  end

  def teardown
    shutdown_bridge
  end

  # ------------------------------------------------------------------
  # End-to-end trampoline delivery
  # ------------------------------------------------------------------

  def test_trampoline_delivers_integer_result
    captured = Queue.new
    ref_addr = LingoFuse::NativeBridge.create_ref(
      ->(result) { captured << result },
      LingoFuse::AsyncSupport::KIND_ASYNC_CALL
    )

    begin
      # The result address is arbitrary in this test; the trampoline
      # forwards it verbatim to the Ruby proc.
      LingoFuse::NativeBridge.test_invoke_async_from_native_thread(
        ref_addr, 0xDEADBEEF
      )

      value = nil
      delivered = wait_until(timeout_s: 2.0, interval_s: 0.01) do
        begin
          value = captured.pop(true)
          true
        rescue ThreadError
          false
        end
      end
      assert delivered, 'async trampoline callback never fired'
      assert_equal 0xDEADBEEF, value
    ensure
      LingoFuse::NativeBridge.free_ref(ref_addr)
    end
  end

  def test_trampoline_passes_nil_for_null_result
    captured = Queue.new
    ref_addr = LingoFuse::NativeBridge.create_ref(
      ->(result) { captured << result },
      LingoFuse::AsyncSupport::KIND_ASYNC_CALL
    )

    begin
      # Qnil → NULL pointer on the C side → the Ruby proc receives nil.
      LingoFuse::NativeBridge.test_invoke_async_from_native_thread(
        ref_addr, nil
      )

      value = :unset
      delivered = wait_until(timeout_s: 2.0, interval_s: 0.01) do
        begin
          value = captured.pop(true)
          true
        rescue ThreadError
          false
        end
      end
      assert delivered, 'async trampoline callback never fired'
      assert_nil value
    ensure
      LingoFuse::NativeBridge.free_ref(ref_addr)
    end
  end

  # ------------------------------------------------------------------
  # Exception isolation
  # ------------------------------------------------------------------

  def test_trampoline_proc_exception_is_isolated
    captured = Queue.new
    ref_addr = LingoFuse::NativeBridge.create_ref(
      ->(_result) do
        captured << :entered
        raise 'intentional failure from trampoline test'
      end,
      LingoFuse::AsyncSupport::KIND_ASYNC_CALL
    )

    begin
      # The trampoline must not propagate the exception. The dispatcher
      # will log it and continue.
      LingoFuse::NativeBridge.test_invoke_async_from_native_thread(
        ref_addr, 0x1234
      )

      marker = nil
      delivered = wait_until(timeout_s: 2.0, interval_s: 0.01) do
        begin
          marker = captured.pop(true)
          true
        rescue ThreadError
          false
        end
      end
      assert delivered, 'trampoline must have entered the proc'
      assert_equal :entered, marker
    ensure
      LingoFuse::NativeBridge.free_ref(ref_addr)
    end
  end
end