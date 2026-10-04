# frozen_string_literal: true
#
# test_native_bridge_self_test.rb — Standalone verification of the
# lingofuse_ext C extension.
#
# This file does NOT load the LingoFuse native library. It only checks
# the extension's own callback marshaling.
#
# ============================================================================
# ARITY CONTRACT
# ============================================================================
# Call            — Proc always receives (input, output); NULL output -> nil.
# Notify          — Proc always receives (input).
# Network connect — Proc always receives (addr_string, nil if NULL addr).
# Network discon  — same.
#
# ============================================================================
# TIMEOUT DISCIPLINE
# ============================================================================
# Every native trigger runs on a watchdog thread with a wall-clock bound.
# ============================================================================

require 'minitest/autorun'

_lib_dir = File.expand_path('../lib', __dir__)
$LOAD_PATH.unshift(_lib_dir) unless $LOAD_PATH.include?(_lib_dir)

begin
  require 'lingofuse_ext'
  EXT_LOADED = true
rescue LoadError => e
  EXT_LOADED = false
  warn "[self-test] lingofuse_ext not available: #{e.message}"
end

class TestNativeBridgeSelfTest < Minitest::Test
  TRIGGER_TIMEOUT_S = 3.0
  DISPATCHER_MUTEX  = Mutex.new

  KIND_CALL               = 0
  KIND_NOTIFY             = 1
  KIND_NETWORK_CONNECT    = 2
  KIND_NETWORK_DISCONNECT = 3

  class << self
    attr_accessor :dispatcher_thread

    def dispatcher_started?
      !dispatcher_thread.nil? && dispatcher_thread.alive?
    end
  end

  def setup
    skip 'lingofuse_ext is not loaded' unless EXT_LOADED

    @nb = LingoFuse::NativeBridge
    ensure_dispatcher_running
  end

  def ensure_dispatcher_running
    return if self.class.dispatcher_started?

    DISPATCHER_MUTEX.synchronize do
      return if self.class.dispatcher_started?

      thread = Thread.new do
        loop do
          begin
            @nb.wait_for_work(100)
            @nb.process_all
          rescue StandardError
            # keep looping
          end
        end
      end
      thread.name = 'lingofuse-ext-self-test-dispatcher' if thread.respond_to?(:name=)
      sleep 0.05

      self.class.dispatcher_thread = thread
    end
  end

  def run_with_timeout
    result = Queue.new

    worker = Thread.new do
      begin
        yield
        result << :ok
      rescue StandardError => e
        result << [:error, e]
      end
    end

    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + TRIGGER_TIMEOUT_S
    loop do
      unless result.empty?
        outcome = result.pop
        worker.join(0.1)
        return outcome
      end
      if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
        worker.kill
        return :timeout
      end
      sleep 0.02
    end
  end

  def pop_with_timeout(queue, timeout_s = 1.0)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout_s
    loop do
      return queue.pop unless queue.empty?
      return nil if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
      sleep 0.01
    end
  end

  # ------------------------------------------------------------------
  # 01 — extension surface
  # ------------------------------------------------------------------

  def test_extension_exposes_expected_methods
    %i[
      create_ref free_ref
      call_trampoline_addr notify_trampoline_addr
      network_connect_trampoline_addr network_disconnect_trampoline_addr
      set_network_refs
      process_all wait_for_work
      test_invoke_from_native_thread
      test_invoke_network_event
      test_invoke_network_event_inplace
    ].each do |m|
      assert_respond_to @nb, m, "NativeBridge must respond to ##{m}"
    end
  end

  def test_trampoline_addresses_are_nonzero_and_distinct
    addrs = [
      @nb.call_trampoline_addr,
      @nb.notify_trampoline_addr,
      @nb.network_connect_trampoline_addr,
      @nb.network_disconnect_trampoline_addr
    ]
    addrs.each { |a| refute_equal 0, a, 'trampoline address must be non-zero' }
    assert_equal addrs.size, addrs.uniq.size,
                 'every trampoline must be a distinct function'
  end

  # ------------------------------------------------------------------
  # 02 — create_ref / free_ref
  # ------------------------------------------------------------------

  def test_create_ref_returns_nonzero_address
    ref = @nb.create_ref(->(_i, _o) {}, KIND_CALL)
    begin
      assert_kind_of Integer, ref
      refute_equal 0, ref
    ensure
      @nb.free_ref(ref)
    end
  end

  def test_create_ref_rejects_non_proc
    assert_raises(TypeError) do
      @nb.create_ref('not a proc', KIND_CALL)
    end
  end

  def test_free_ref_with_zero_is_a_noop
    assert_nil @nb.free_ref(0)
  end

  # ------------------------------------------------------------------
  # 03 — wait_for_work on an empty queue
  # ------------------------------------------------------------------

  def test_wait_for_work_returns_false_when_queue_is_empty
    has_work = @nb.wait_for_work(30)
    assert_equal false, has_work
  end

  # ------------------------------------------------------------------
  # 04 — Call trigger round trip
  # ------------------------------------------------------------------

  def test_call_trigger_invokes_proc_with_two_args
    captured = Queue.new

    ref = @nb.create_ref(
      ->(input_addr, output_addr) { captured << [input_addr, output_addr] },
      KIND_CALL
    )
    begin
      outcome = run_with_timeout do
        @nb.test_invoke_from_native_thread(ref, 0x1000, 0x2000, false)
      end
      assert_equal :ok, outcome

      pair = pop_with_timeout(captured, 1.0)
      refute_nil pair
      assert_equal 0x1000, pair[0]
      assert_equal 0x2000, pair[1]
    ensure
      @nb.free_ref(ref)
    end
  end

  # ------------------------------------------------------------------
  # 05 — Call trigger with NULL output still passes two args
  # ------------------------------------------------------------------

  def test_call_trigger_with_null_output_still_passes_two_args
    captured = Queue.new

    ref = @nb.create_ref(
      ->(input_addr, output_addr) { captured << [input_addr, output_addr] },
      KIND_CALL
    )
    begin
      outcome = run_with_timeout do
        @nb.test_invoke_from_native_thread(ref, 0xAA, 0, false)
      end
      assert_equal :ok, outcome

      pair = pop_with_timeout(captured, 1.0)
      refute_nil pair
      assert_equal 0xAA, pair[0]
      assert_nil pair[1]
    ensure
      @nb.free_ref(ref)
    end
  end

  # ------------------------------------------------------------------
  # 06 — Notify trigger
  # ------------------------------------------------------------------

  def test_notify_trigger_invokes_proc_with_one_arg
    captured = Queue.new

    ref = @nb.create_ref(
      ->(input_addr) { captured << input_addr },
      KIND_NOTIFY
    )
    begin
      outcome = run_with_timeout do
        @nb.test_invoke_from_native_thread(ref, 0xABCD, nil, true)
      end
      assert_equal :ok, outcome

      got = pop_with_timeout(captured, 1.0)
      assert_equal 0xABCD, got
    ensure
      @nb.free_ref(ref)
    end
  end

  # ------------------------------------------------------------------
  # 07 — Proc runs on a Ruby thread
  # ------------------------------------------------------------------

  def test_proc_runs_on_a_ruby_thread
    captured_thread = Queue.new

    ref = @nb.create_ref(
      ->(_i, _o) { captured_thread << Thread.current },
      KIND_CALL
    )
    begin
      outcome = run_with_timeout do
        @nb.test_invoke_from_native_thread(ref, 0xAA, 0xBB, false)
      end
      assert_equal :ok, outcome

      runner = pop_with_timeout(captured_thread, 1.0)
      refute_nil runner
      assert_kind_of Thread, runner
      refute_equal Thread.main, runner
    ensure
      @nb.free_ref(ref)
    end
  end

  # ------------------------------------------------------------------
  # 08 — exception isolation (Call)
  # ------------------------------------------------------------------

  def test_proc_exception_does_not_block_the_trampoline
    started = Queue.new

    ref = @nb.create_ref(
      ->(_i, _o) do
        started << :entered
        raise 'intentional failure from self-test'
      end,
      KIND_CALL
    )
    begin
      outcome = run_with_timeout do
        @nb.test_invoke_from_native_thread(ref, 0xAA, 0xBB, false)
      end
      assert_equal :ok, outcome

      marker = pop_with_timeout(started, 1.0)
      assert_equal :entered, marker
    ensure
      @nb.free_ref(ref)
    end
  end

  # ------------------------------------------------------------------
  # 09 — concurrent triggers
  # ------------------------------------------------------------------

  def test_concurrent_triggers_all_deliver
    count = 5
    captured = Queue.new

    refs = (0...count).map do
      @nb.create_ref(->(input_addr, _o) { captured << input_addr }, KIND_CALL)
    end
    begin
      threads = refs.each_with_index.map do |ref, idx|
        Thread.new do
          @nb.test_invoke_from_native_thread(ref, 0x100 + idx, 0x200 + idx, false)
        end
      end

      joined = threads.map { |t| t.join(TRIGGER_TIMEOUT_S) }
      refute_includes joined, nil

      got = []
      while (v = pop_with_timeout(captured, 0.2))
        got << v
      end

      assert_equal count, got.size
      assert_equal (0...count).map { |i| 0x100 + i }.sort, got.sort
    ensure
      refs.each { |r| @nb.free_ref(r) }
    end
  end

  # ------------------------------------------------------------------
  # 10 — sequential FIFO
  # ------------------------------------------------------------------

  def test_sequential_triggers_preserve_fifo_order
    captured = Queue.new
    ref = @nb.create_ref(->(i, _o) { captured << i }, KIND_CALL)
    begin
      3.times do |i|
        outcome = run_with_timeout do
          @nb.test_invoke_from_native_thread(ref, i, 0x100 + i, false)
        end
        assert_equal :ok, outcome
      end

      got = []
      while (v = pop_with_timeout(captured, 0.2))
        got << v
      end

      assert_equal [0, 1, 2], got
    ensure
      @nb.free_ref(ref)
    end
  end

  # ------------------------------------------------------------------
  # 11 — network event from a native thread
  # ------------------------------------------------------------------

  def test_network_connect_event_from_native_thread
    captured = Queue.new

    ref = @nb.create_ref(
      ->(addr) { captured << addr },
      KIND_NETWORK_CONNECT
    )
    begin
      # Install the ref into the C-side global so the trampoline can find it.
      @nb.set_network_refs(ref, nil)

      outcome = run_with_timeout do
        @nb.test_invoke_network_event(ref, 'ipc:example:0', KIND_NETWORK_CONNECT)
      end

      assert_equal :ok, outcome

      addr = pop_with_timeout(captured, 1.0)
      assert_equal 'ipc:example:0', addr
    ensure
      @nb.set_network_refs(nil, nil)
      @nb.free_ref(ref)
    end
  end

  def test_network_disconnect_event_from_native_thread
    captured = Queue.new

    ref = @nb.create_ref(
      ->(addr) { captured << addr },
      KIND_NETWORK_DISCONNECT
    )
    begin
      @nb.set_network_refs(nil, ref)

      outcome = run_with_timeout do
        @nb.test_invoke_network_event(ref, 'ipc:gone:0', KIND_NETWORK_DISCONNECT)
      end
      assert_equal :ok, outcome

      addr = pop_with_timeout(captured, 1.0)
      assert_equal 'ipc:gone:0', addr
    ensure
      @nb.set_network_refs(nil, nil)
      @nb.free_ref(ref)
    end
  end

  # ------------------------------------------------------------------
  # 12 — network event in place (GVL held)
  # ------------------------------------------------------------------

  def test_network_connect_event_in_place
    captured = Queue.new

    ref = @nb.create_ref(
      ->(addr) { captured << addr },
      KIND_NETWORK_CONNECT
    )
    begin
      @nb.set_network_refs(ref, nil)

      @nb.test_invoke_network_event_inplace(ref, 'ipc:inplace:0', KIND_NETWORK_CONNECT)

      addr = pop_with_timeout(captured, 1.0)
      assert_equal 'ipc:inplace:0', addr
    ensure
      @nb.set_network_refs(nil, nil)
      @nb.free_ref(ref)
    end
  end

  # ------------------------------------------------------------------
  # 13 — network event with NULL addr passes nil
  # ------------------------------------------------------------------

  def test_network_event_with_null_addr_passes_nil
    captured = Queue.new

    ref = @nb.create_ref(
      ->(addr) { captured << addr },
      KIND_NETWORK_CONNECT
    )
    begin
      @nb.set_network_refs(ref, nil)

      outcome = run_with_timeout do
        @nb.test_invoke_network_event(ref, nil, KIND_NETWORK_CONNECT)
      end
      assert_equal :ok, outcome

      addr = pop_with_timeout(captured, 1.0)
      assert_nil addr
    ensure
      @nb.set_network_refs(nil, nil)
      @nb.free_ref(ref)
    end
  end

  # ------------------------------------------------------------------
  # 14 — network event exception isolation
  # ------------------------------------------------------------------

  def test_network_event_exception_does_not_block
    started = Queue.new

    ref = @nb.create_ref(
      ->(_addr) do
        started << :entered
        raise 'intentional network failure'
      end,
      KIND_NETWORK_CONNECT
    )
    begin
      @nb.set_network_refs(ref, nil)

      outcome = run_with_timeout do
        @nb.test_invoke_network_event(ref, 'ipc:x', KIND_NETWORK_CONNECT)
      end
      assert_equal :ok, outcome

      marker = pop_with_timeout(started, 1.0)
      assert_equal :entered, marker
    ensure
      @nb.set_network_refs(nil, nil)
      @nb.free_ref(ref)
    end
  end
end