# frozen_string_literal: true
#
# async_support.rb — Safe lifetime management and future-style wrappers
# for LingoFuse's asynchronous call primitives.
#
# ============================================================================
# WHY THIS FILE EXISTS
# ============================================================================
# The C extension (lingofuse_ext.c) hands a raw C function pointer to
# LingoFuse and installs it as the callback for an asynchronous request.
# Three hazards arise from the C-side contract that we cannot safely
# delegate to naive caller code:
#
#   1. PREMATURE RELEASE ON TIMEOUT
#
#      A timed-out async request is NOT cancelled by the C library.
#      The framework will still invoke the callback when (or if) the
#      response arrives. If we release the CallbackRef the moment the
#      Ruby-side timeout fires, the C side is left holding a dangling
#      pointer, and the next invocation crashes the process.
#
#   2. LEAK ON DISPATCH FAILURE
#
#      If the C library rejects the request before dispatching it
#      (LF_Async_Call returns 0), the callback will NEVER fire. A
#      naive "wait for the callback to release the ref" policy leaks
#      the CallbackRef and its registered Proc forever.
#
#   3. DOUBLE-RELEASE RACES
#
#      The caller thread (on timeout) and the dispatcher thread (on
#      callback) can race to release the same ref. Without an explicit
#      state machine, this leads to use-after-free.
#
# AsyncBridge addresses all three hazards:
#
#   * Every operation is wrapped in an AsyncOp with an explicit state
#     machine (PENDING -> FIRED | ABANDONED | NOT_QUEUED).
#
#   * Only the bridge releases a ref, and only after one of:
#       - the callback has fired (state FIRED), or
#       - a configurable grace period has elapsed since the timeout
#         fired (state ABANDONED), giving any late callback a chance
#         to arrive on a still-valid Ruby object.
#
#   * Dispatch failure releases the ref immediately (state NOT_QUEUED),
#     because the C side never received the pointer.
#
# ============================================================================
# THREADING MODEL
# ============================================================================
# Three threads are involved:
#
#   CALLER THREAD   — the Ruby thread that calls run_async_with_future.
#                     Creates the op, registers it, dispatches the C
#                     request, and may subsequently block on
#                     CallFuture#value.
#
#   DISPATCHER      — the Ruby thread started by NativeBridge.start.
#                     Runs the loop:
#                       wait_for_work(100)
#                       process_all
#                     When an async result arrives, the C extension's
#                     trampoline_async_call enqueues a CallbackItem and
#                     blocks the native worker thread. The dispatcher
#                     dequeues it and invokes our user proc.
#
#   RECLAIM THREAD  — the thread started by AsyncBridge. Periodically
#                     scans the timeout and release queues and frees
#                     the refs whose state machine permits.
#
# All three coordinate through two mutexes:
#
#   * AsyncOp's @mutex guards the per-op state transitions.
#
#   * AsyncBridge's @mutex guards the queues and the active set.
#
# The op's @mutex is never held while calling into the bridge, and the
# bridge's @mutex is never held while calling into user code or the C
# extension. This avoids lock-order inversions.
#
# ============================================================================
# GVL REQUIREMENT
# ============================================================================
# The C extension's free_ref calls rb_gc_unregister_address, which
# requires the GVL. The reclaim thread is a plain Ruby Thread, so it
# holds the GVL when it runs. All ref releases go through the reclaim
# thread (or through the caller thread on the immediate-release path),
# both of which hold the GVL.
#
# ============================================================================
# WHAT THIS FILE DOES NOT DO
# ============================================================================
#   * It does NOT cancel C-side requests. CallFuture#value with a
#     timeout only stops WAITING; the C request continues and its
#     result is discarded when it arrives.
#
#   * It does NOT provide a C-side timeout. LF_Async_Call has no
#     timeout parameter; the timeout applied here is purely a Ruby-
#     side decision.
#
#   * It does NOT reorder or batch callbacks. Each op is independent.
#
# All comments and messages are in English.
# ============================================================================

require 'thread'

require_relative 'errors'
require_relative 'native_bridge'

module LingoFuse
  # --------------------------------------------------------------------
  # TimeoutError
  # --------------------------------------------------------------------
  # Raised by CallFuture#value when the caller-supplied wait window
  # expires, and by AsyncOp#abandon! when the bridge's own timeout
  # fires. Not present in errors.rb (that file predates the async
  # subsystem); defined here for cohesion.
  #
  # Re-opening is harmless in Ruby, so repeated require is safe.
  class TimeoutError < Error
  end

  # --------------------------------------------------------------------
  # AsyncSupport
  # --------------------------------------------------------------------

  module AsyncSupport
    #: Callback-kind constant shared with the C extension. MUST equal
    #: LF_KIND_ASYNC_CALL in lingofuse_ext.c. Any change here is a
    #: wire-format change and requires a matching edit on the C side.
    KIND_ASYNC_CALL = 4

    #: Default grace window, in seconds, between a timeout firing and
    #: the ref being released. Long enough that a late callback on a
    #: slow network link still finds a live Ruby object.
    DEFAULT_GRACE_SECONDS = 60.0

    #: Default period, in seconds, between two reclaim sweeps.
    DEFAULT_RECLAIM_PERIOD = 1.0

    # ==================================================================
    # CallFuture
    # ==================================================================
    #
    # A minimal, thread-safe Future. Unlike the Python binding, which
    # subclasses concurrent.futures.Future, Ruby has no standard Future
    # class; the implementation here is small enough to own outright.
    #
    # Public surface:
    #
    #   value(timeout_ms: nil) -> value or raise
    #   done?                  -> true once resolved (fulfilled or rejected)
    #   abandoned?             -> true once the caller or bridge gave up
    #
    # A future is resolved exactly once: either fulfill or reject wins,
    # and all subsequent calls to fulfill/reject are no-ops. The
    # `abandoned?` flag is independent of `done?`: it can be set while
    # the future is still pending (caller timeout) and stays set after
    # the future is later resolved by a late callback.
    class CallFuture
      def initialize
        @mutex = Mutex.new
        @cv = ConditionVariable.new
        @done = false
        @value = nil
        @error = nil
        @abandoned = false
      end

      # Resolve the future with a value. No-op if already resolved.
      def fulfill(value)
        @mutex.synchronize do
          return if @done
          @done = true
          @value = value
          @cv.broadcast
        end
        nil
      end

      # Resolve the future with an exception. No-op if already resolved.
      def reject(error)
        @mutex.synchronize do
          return if @done
          @done = true
          @error = error
          @cv.broadcast
        end
        nil
      end

      # Mark the future as abandoned. Idempotent. Does NOT resolve the
      # future; a later callback may still fulfill or reject it.
      def mark_abandoned!
        @mutex.synchronize { @abandoned = true }
        nil
      end

      def done?
        @mutex.synchronize { @done }
      end

      def abandoned?
        @mutex.synchronize { @abandoned }
      end

      # Block until the future is resolved or the wait window expires.
      #
      # With timeout_ms: nil, waits indefinitely.
      # With timeout_ms: Integer > 0, waits at most that many ms. On
      # expiry, marks the future abandoned and raises TimeoutError.
      # The C request is NOT cancelled; a subsequent value() call may
      # still observe a fulfilled future if the callback later arrives.
      def value(timeout_ms: nil)
        @mutex.synchronize do
          wait_for_resolution(timeout_ms)

          unless @done
            # Local wait expired before the callback arrived.
            @abandoned = true
            raise TimeoutError.new(
              "CallFuture#value timed out after #{timeout_ms}ms"
            )
          end

          raise @error if @error
          @value
        end
      end
      alias result value

      private

      def wait_for_resolution(timeout_ms)
        return if @done

        if timeout_ms.nil?
          @cv.wait(@mutex) while !@done
          return
        end

        deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) +
                   (timeout_ms.to_f / 1000.0)

        until @done
          remaining = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
          break if remaining <= 0
          @cv.wait(@mutex, remaining)
        end
      end
    end

    # ==================================================================
    # AsyncOp
    # ==================================================================
    #
    # A single outstanding asynchronous operation.
    #
    # Owns:
    #   * the CallbackRef returned by NativeBridge.create_ref
    #   * the Ruby Proc that the C extension's trampoline_async_call will
    #     invoke on the dispatcher thread
    #   * the CallFuture that receives the resolved value (or nil for
    #     the legacy callback-style API, which is not implemented in
    #     this file)
    #
    # State machine:
    #
    #   PENDING     --(callback fires)-->  FIRED
    #   PENDING     --(timeout fires)-->   ABANDONED --(callback fires)--> FIRED
    #   PENDING     --(dispatch fails)-->  NOT_QUEUED
    #
    # FIRED means the callback has completed its Ruby-side work.
    # ABANDONED means the bridge's timeout fired while still PENDING;
    # the op is kept alive for a grace period.
    # NOT_QUEUED means the C dispatch failed before installing the
    # callback.
    #
    # All transitions are guarded by @mutex. The Proc is invoked OUTSIDE
    # the lock so that a slow or blocking Proc cannot stall other
    # state transitions.
    class AsyncOp
      STATE_PENDING    = :pending
      STATE_FIRED      = :fired
      STATE_ABANDONED  = :abandoned
      STATE_NOT_QUEUED = :not_queued

      attr_reader :ref_addr, :future

      def initialize(proc, kind, future: nil)
        raise ArgumentError, 'proc must respond to #call' unless proc.respond_to?(:call)

        @proc = proc
        @kind = kind
        @future = future
        @state = STATE_PENDING
        @mutex = Mutex.new
        @released = false

        # Allocate the C-side CallbackRef. The C extension's
        # rb_gc_register_address keeps the Proc alive; we keep the
        # returned address in @ref_addr so we can free it later.
        @ref_addr = LingoFuse::NativeBridge.create_ref(proc, kind)
      end

      def state
        @mutex.synchronize { @state }
      end

      # Called by the caller thread when LF_Async_* returned a value
      # other than 1. Releases the ref immediately.
      #
      # Returns true if the transition happened (op was PENDING),
      # false otherwise.
      def mark_not_queued!
        changed = @mutex.synchronize do
          if @state == STATE_PENDING
            @state = STATE_NOT_QUEUED
            true
          else
            false
          end
        end

        AsyncBridge.instance.schedule_release_now(self) if changed
        changed
      end

      # Called by the reclaim thread when the bridge's timeout fires.
      # Rejects the future with TimeoutError and schedules release
      # after the grace period.
      #
      # Returns true if the transition happened.
      def abandon!
        changed = @mutex.synchronize do
          if @state == STATE_PENDING
            @state = STATE_ABANDONED
            true
          else
            false
          end
        end

        return false unless changed

        if @future
          @future.mark_abandoned!
          unless @future.done?
            @future.reject(
              TimeoutError.new(
                'LingoFuse async call abandoned after timeout; the ' \
                'C-side request may still be in flight, but its result ' \
                'will be discarded.'
              )
            )
          end
        end

        AsyncBridge.instance.schedule_release_after_grace(self)
        true
      end

      # Called by the dispatcher thread when the C trampoline fires.
      # Runs the user Proc (which reads the result handle and resolves
      # the future), then schedules immediate release.
      def invoke_from_c(result_addr)
        transition = @mutex.synchronize do
          case @state
          when STATE_FIRED, STATE_NOT_QUEUED
            :already_done
          when STATE_ABANDONED
            # Late callback after timeout: still transition to FIRED
            # so the ref can be released promptly, but do NOT deliver
            # the result (the future is already rejected).
            @state = STATE_FIRED
            :late
          when STATE_PENDING
            @state = STATE_FIRED
            :normal
          end
        end

        case transition
        when :already_done
          return
        when :late
          AsyncBridge.instance.schedule_release_now(self)
          return
        when :normal
          begin
            @proc.call(result_addr)
          rescue StandardError => e
            warn "[LingoFuse::AsyncOp] callback raised: #{e.class}: #{e.message}"
          ensure
            AsyncBridge.instance.schedule_release_now(self)
          end
        end
      end

      # Called by the reclaim thread (or the caller thread on the
      # immediate-release path). Frees the C-side CallbackRef.
      # Idempotent.
      def release!
        already = @mutex.synchronize do
          return true if @released
          @released = true
          false
        end
        return true if already

        LingoFuse::NativeBridge.free_ref(@ref_addr)
        true
      rescue StandardError => e
        warn "[LingoFuse::AsyncOp] free_ref failed: #{e.class}: #{e.message}"
        false
      end
    end

    # ==================================================================
    # AsyncBridge
    # ==================================================================
    #
    # Process-wide singleton that owns every live AsyncOp and runs the
    # reclamation thread.
    #
    # Public surface:
    #
    #   AsyncBridge.instance               -> singleton
    #   AsyncBridge.shutdown_instance      -> release singleton
    #   bridge.register(op)                -> register a PENDING op
    #   bridge.schedule_timeout(op, ms)    -> arm a timeout
    #   bridge.stats                       -> diagnostic counters
    #   bridge.shutdown                    -> release everything
    #
    # The singleton is thread-safe for construction and shutdown.
    # Tests may replace the singleton between cases via
    # shutdown_instance + instance.
    class AsyncBridge
      @instance = nil
      @instance_mutex = Mutex.new

      class << self
        def instance
          @instance_mutex.synchronize do
            @instance ||= new
          end
        end

        # Releases the singleton, if any. Safe to call multiple times.
        # Intended for tests and process teardown.
        def shutdown_instance
          inst = nil
          @instance_mutex.synchronize do
            inst = @instance
            @instance = nil
          end
          inst&.shutdown
          nil
        end
      end

      # Exposed as attributes rather than module constants so that
      # tests can override them per-instance without re-importing.
      attr_accessor :grace_seconds, :period_seconds

      def initialize
        @active = {}         # id => AsyncOp
        @counter = 0
        @release_count = 0

        @mutex = Mutex.new
        @cv = ConditionVariable.new

        @timeout_queue        = []   # [[deadline, op], ...]
        @release_now_queue    = []   # [[now, op], ...]
        @release_after_queue  = []   # [[deadline, op], ...]

        @shutdown = false
        @grace_seconds = DEFAULT_GRACE_SECONDS
        @period_seconds = DEFAULT_RECLAIM_PERIOD

        @thread = Thread.new { reclaim_loop }
        @thread.report_on_exception = false
        @thread.abort_on_exception = false
        if @thread.respond_to?(:name=)
          @thread.name = 'lingofuse-async-reclaim'
        end
      end

      # Register a newly-created PENDING op. Must be called BEFORE the
      # op's ref is handed to the C library, so that a callback can
      # never fire on a ref the bridge does not know about.
      def register(op)
        @mutex.synchronize do
          @counter += 1
          @active[@counter] = op
        end
        nil
      end

      # Arm a timeout on a registered op.
      def schedule_timeout(op, timeout_ms)
        return if timeout_ms.nil? || timeout_ms.to_i <= 0
        deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) +
                   (timeout_ms.to_f / 1000.0)
        @mutex.synchronize do
          @timeout_queue << [deadline, op]
          @cv.broadcast
        end
        nil
      end

      # Request immediate release. Called from the caller thread on
      # dispatch failure, and from the dispatcher thread after a
      # callback has been fully processed.
      def schedule_release_now(op)
        @mutex.synchronize do
          @release_now_queue << [Process.clock_gettime(Process::CLOCK_MONOTONIC), op]
          @cv.broadcast
        end
        nil
      end

      # Request release after the configured grace period. Called from
      # the reclaim thread when an op has been abandoned.
      def schedule_release_after_grace(op)
        deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) +
                   @grace_seconds
        @mutex.synchronize do
          @release_after_queue << [deadline, op]
          @cv.broadcast
        end
        nil
      end

      def stats
        @mutex.synchronize do
          active = @active.values
          counts = {
            AsyncOp::STATE_PENDING    => 0,
            AsyncOp::STATE_FIRED      => 0,
            AsyncOp::STATE_ABANDONED  => 0,
            AsyncOp::STATE_NOT_QUEUED => 0
          }
          active.each { |op| counts[op.state] = counts.fetch(op.state, 0) + 1 }

          {
            total: active.size,
            pending: counts[AsyncOp::STATE_PENDING],
            fired: counts[AsyncOp::STATE_FIRED],
            abandoned: counts[AsyncOp::STATE_ABANDONED],
            not_queued: counts[AsyncOp::STATE_NOT_QUEUED],
            released_total: @release_count,
            grace_seconds: @grace_seconds,
            period_seconds: @period_seconds
          }
        end
      end

      def shutdown
        @mutex.synchronize do
          return if @shutdown
          @shutdown = true
          @cv.broadcast
        end
        @thread.join(2.0)
        nil
      end

      # -----------------------------------------------------------------
      # Reclamation thread
      # -----------------------------------------------------------------

      private

      def reclaim_loop
        loop do
          @mutex.synchronize do
            return if @shutdown
            @cv.wait(@mutex, @period_seconds)
            return if @shutdown
          end
          reclaim_once
        end
      rescue StandardError => e
        warn "[LingoFuse::AsyncBridge] reclaim_loop error: #{e.class}: #{e.message}"
        retry unless @shutdown
      end

      def reclaim_once
        now = Process.clock_gettime(Process::CLOCK_MONOTONIC)

        timeouts = []
        releases = []

        @mutex.synchronize do
          # --- 1. Expired timeouts ----------------------------------
          remaining_timeouts = []
          @timeout_queue.each do |deadline, op|
            if deadline <= now
              timeouts << op
            else
              remaining_timeouts << [deadline, op]
            end
          end
          @timeout_queue = remaining_timeouts

          # --- 2. Immediate releases --------------------------------
          @release_now_queue.each { |_, op| releases << op }
          @release_now_queue.clear

          # --- 3. Grace-period releases -----------------------------
          remaining_after = []
          @release_after_queue.each do |deadline, op|
            if deadline <= now
              releases << op
            else
              remaining_after << [deadline, op]
            end
          end
          @release_after_queue = remaining_after
        end

        # Process outside the bridge lock. Both operations may take
        # non-trivial time (abandon! rejects a future and wakes waiters;
        # release! calls into the C extension), and neither should
        # block the bridge's queue mutations.
        timeouts.each { |op| op.abandon! }
        releases.each { |op| release_op(op) }
      end

      def release_op(op)
        @mutex.synchronize do
          @active.delete_if { |_, v| v.equal?(op) }
          @release_count += 1
        end
        op.release!
      rescue StandardError => e
        warn "[LingoFuse::AsyncBridge] release_op error: #{e.class}: #{e.message}"
      end
    end

    # ==================================================================
    # run_async_with_future
    # ==================================================================
    #
    # One-stop factory: create op + future, register the op, dispatch
    # the C request, arm the timeout on success, and return the future.
    #
    # Parameters:
    #
    #   issue_fn:    A callable that receives the CallbackRef address
    #                and issues the C-side request. Must return 1 on
    #                successful dispatch, or any other value on failure.
    #                Typical implementation:
    #
    #                  ->(ref_addr) {
    #                    LingoFuse::NativeBridge.lf_async_call(
    #                      app_name, param_handle, ref_addr, trampoline_addr
    #                    )
    #                  }
    #
    #   deserialize: A callable that receives the result handle address
    #                (an Integer) or nil and returns a Ruby value. The
    #                result handle is alive ONLY during this call; the
    #                deserializer MUST copy everything it needs out
    #                before returning.
    #
    #                Passing nil uses the identity function (the
    #                callback receives the raw Integer address).
    #
    #   timeout_ms:  Optional Ruby-side timeout in milliseconds. When
    #                the timeout fires before the callback arrives, the
    #                future is rejected with TimeoutError and its
    #                abandoned? flag is set. The C request is NOT
    #                cancelled.
    #
    # Returns a CallFuture. Never raises for a well-formed issue_fn; if
    # issue_fn raises, the exception propagates to the caller AFTER the
    # op has been marked not-queued, so no ref leaks.
    def self.run_async_with_future(issue_fn:, deserialize: nil, timeout_ms: nil)
      raise ArgumentError, 'issue_fn must respond to #call' unless issue_fn.respond_to?(:call)

      deserialize ||= ->(addr) { addr }

      future = CallFuture.new

      # The user proc that will be invoked on the dispatcher thread when
      # the C trampoline fires. The variable `op` is captured by the
      # closure and assigned below; at call time it is always set.
      op = nil
      user_proc = lambda do |result_addr|
        begin
          if result_addr.nil?
            # Null result: the C side ran the callback with a NULL
            # pointer, which occurs on timeout or internal failure.
            future.fulfill(nil) unless future.done?
          else
            value = deserialize.call(result_addr)
            future.fulfill(value) unless future.done?
          end
        rescue StandardError => e
          future.reject(e) unless future.done?
        end
      end

      op = AsyncOp.new(user_proc, KIND_ASYNC_CALL, future: future)
      bridge = AsyncBridge.instance
      bridge.register(op)

      begin
        ret = issue_fn.call(op.ref_addr)
      rescue StandardError
        op.mark_not_queued!
        raise
      end

      if ret != 1
        op.mark_not_queued!
        unless future.done?
          future.reject(
            Error.new(
              "async request was not queued " \
              "(dispatch returned #{ret.inspect})"
            )
          )
        end
        return future
      end

      bridge.schedule_timeout(op, timeout_ms) if timeout_ms
      future
    end
  end

  # --------------------------------------------------------------------
  # Top-level aliases
  # --------------------------------------------------------------------
  # Provide LingoFuse::CallFuture, LingoFuse::AsyncOp, etc. so that
  # callers can write `LingoFuse::CallFuture` without the intermediate
  # module path. This mirrors the Python binding's flat namespace.

  CallFuture    = AsyncSupport::CallFuture    unless const_defined?(:CallFuture, false)
  AsyncOp       = AsyncSupport::AsyncOp       unless const_defined?(:AsyncOp, false)
  AsyncBridge   = AsyncSupport::AsyncBridge   unless const_defined?(:AsyncBridge, false)

  class << self
    def run_async_with_future(**kwargs)
      AsyncSupport.run_async_with_future(**kwargs)
    end
  end
end