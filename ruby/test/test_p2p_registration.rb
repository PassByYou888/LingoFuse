# frozen_string_literal: true
#
# test_p2p_registration.rb — Unit tests for LingoFuse::P2PRegistration.
#
# ============================================================================
# COVERAGE
# ============================================================================
# Four test classes cover the process-wide P2P registration surface:
#
#   1. TestP2PRegistration
#        Register / unregister / duplicate / unknown-name semantics,
#        and the registered? / registered_names query surface.
#
#   2. TestP2PTopLevelAliases
#        The LingoFuse.register_p2p_call / register_p2p_notify /
#        unregister_p2p top-level aliases.
#
#   3. TestP2PRegistryLifetime
#        Registry consistency under concurrency, and the isolation
#        between P2P registration and App-bound registration.
#
#   4. TestP2PCallbackWiring
#        After registering a Call / Notify API, verify that the
#        wrapper closure is correctly wired to the C extension's
#        trampoline by triggering it through the test-only
#        NativeBridge helpers. No real network is involved.
#
# ============================================================================
# QUEUE DRAIN CONVENTION — READ BEFORE EDITING
# ============================================================================
# Ruby's Thread::Queue has two pop forms:
#
#     q.pop       — blocks until an item is available
#     q.pop(true) — historically, raise ThreadError when empty
#
# On Ruby 4.0 the non-blocking form is unreliable: in some
# environments it blocks instead of raising, which deadlocks the
# process and trips the runtime's own "No live threads left" guard.
#
# Every drain in this file therefore follows ONE rule:
#
#     until q.empty?
#       ...
#       q.pop
#     end
#
# or, equivalently:
#
#     unless q.empty?
#       ... q.pop ...
#     end
#
# The `q.pop` call is guarded by an explicit `empty?` check on the
# SAME thread that will consume it. Never call `q.pop` unguarded, and
# never place a `q.pop` call inside an assertion message: Ruby
# evaluates assertion arguments BEFORE calling the assertion, so a
# `q.pop` embedded in a failure message would run even when the
# assertion is about to succeed.
#
# ============================================================================
# TESTING NOTES
# ============================================================================
# * Every test uses a UUID-suffixed API name so that a failed cleanup
#   in one test cannot poison a later test.
#
# * Teardown makes a best-effort attempt to unregister every name the
#   test class registered, even if the test itself failed midway.
#
# * The CallbackWiring tests require the C extension; they are skipped
#   when NativeBridge is not available.
#
# * All output is in English.
# ============================================================================

require 'minitest/autorun'
require 'securerandom'

_lib_dir = File.expand_path('../lib', __dir__)
$LOAD_PATH.unshift(_lib_dir) unless $LOAD_PATH.include?(_lib_dir)

begin
  require 'lingofuse'
rescue StandardError, LoadError => e
  warn "Failed to load LingoFuse: #{e.class}: #{e.message}"
end

# ======================================================================
# Watchdog helper
# ======================================================================

# Run `block` on a worker thread with a wall-clock bound.
#
# Returns:
#   :ok         — block completed
#   :timeout    — block did not complete within `timeout_s`
#   [:error, e] — block raised
def run_with_timeout(timeout_s = 3.0)
  result = Queue.new

  worker = Thread.new do
    begin
      yield
      result << :ok
    rescue StandardError => e
      result << [:error, e]
    end
  end

  deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout_s
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

# ======================================================================
# Common base class
# ======================================================================

class P2PTestBase < Minitest::Test
  def setup
    unless defined?(LingoFuse::P2PRegistration) && LingoFuse.loaded?
      skip 'native library not loaded; P2P registration tests are skipped'
    end

    @registered_names = []
  end

  def teardown
    @registered_names.each do |name|
      LingoFuse::P2PRegistration.unregister(name)
    rescue StandardError
      # ignored: teardown must not mask a test failure
    end
    @registered_names.clear
  end

  def unique_api_name(prefix = 'p2p_test')
    "#{prefix}_#{Process.pid}_#{SecureRandom.hex(4)}"
  end

  def register_call_tracked(name, description = '', &block)
    block ||= ->(_input, _output) {}
    LingoFuse::P2PRegistration.register_call(name, description, &block)
    @registered_names << name
    name
  end

  def register_notify_tracked(name, description = '', &block)
    block ||= ->(_input) {}
    LingoFuse::P2PRegistration.register_notify(name, description, &block)
    @registered_names << name
    name
  end
end

# ======================================================================
# Registration semantics
# ======================================================================

class TestP2PRegistration < P2PTestBase
  def test_register_call_succeeds
    name = unique_api_name('call')
    result = LingoFuse::P2PRegistration.register_call(name, 'desc') do |_i, _o|
    end
    @registered_names << name

    assert_equal true, result
    assert LingoFuse::P2PRegistration.registered?(name)
  end

  def test_register_call_without_block_raises
    name = unique_api_name('no_block')
    assert_raises(ArgumentError) do
      LingoFuse::P2PRegistration.register_call(name, 'desc')
    end
    refute LingoFuse::P2PRegistration.registered?(name)
  end

  def test_register_call_with_nil_name_raises
    assert_raises(ArgumentError) do
      LingoFuse::P2PRegistration.register_call(nil, 'desc') { |_i, _o| }
    end
  end

  def test_register_notify_succeeds
    name = unique_api_name('notify')
    result = LingoFuse::P2PRegistration.register_notify(name, 'desc') do |_i|
    end
    @registered_names << name

    assert_equal true, result
    assert LingoFuse::P2PRegistration.registered?(name)
  end

  def test_register_notify_without_block_raises
    name = unique_api_name('no_block')
    assert_raises(ArgumentError) do
      LingoFuse::P2PRegistration.register_notify(name, 'desc')
    end
  end

  def test_duplicate_call_registration_raises
    name = register_call_tracked(unique_api_name('dup'))

    err = assert_raises(LingoFuse::RegistrationError) do
      LingoFuse::P2PRegistration.register_call(name, 'duplicate') do |_i, _o|
      end
    end
    assert_equal name, err.api_name
  end

  def test_duplicate_notify_registration_raises
    name = register_notify_tracked(unique_api_name('dup'))

    assert_raises(LingoFuse::RegistrationError) do
      LingoFuse::P2PRegistration.register_notify(name, 'duplicate') do |_i|
      end
    end
  end

  def test_unregister_returns_true_for_registered_name
    name = register_call_tracked(unique_api_name('unreg'))

    assert_equal true, LingoFuse::P2PRegistration.unregister(name)
    refute LingoFuse::P2PRegistration.registered?(name)

    @registered_names.delete(name)
  end

  def test_unregister_returns_false_for_unknown_name
    name = unique_api_name('never_registered')
    assert_equal false, LingoFuse::P2PRegistration.unregister(name)
  end

  def test_unregister_nil_returns_false
    assert_equal false, LingoFuse::P2PRegistration.unregister(nil)
  end

  def test_unregister_then_reregister_succeeds
    name = register_call_tracked(unique_api_name('hot'))

    LingoFuse::P2PRegistration.unregister(name)
    @registered_names.delete(name)

    result = LingoFuse::P2PRegistration.register_call(name, 'v2') do |_i, _o|
    end
    @registered_names << name
    assert_equal true, result
    assert LingoFuse::P2PRegistration.registered?(name)
  end

  def test_registered_predicate_returns_boolean
    name = unique_api_name('pred')
    refute LingoFuse::P2PRegistration.registered?(name)

    register_call_tracked(name)
    assert LingoFuse::P2PRegistration.registered?(name)
  end

  def test_registered_predicate_nil_returns_false
    assert_equal false, LingoFuse::P2PRegistration.registered?(nil)
  end

  def test_registered_names_returns_snapshot
    name_a = register_call_tracked(unique_api_name('snap_a'))
    name_b = register_notify_tracked(unique_api_name('snap_b'))

    names = LingoFuse::P2PRegistration.registered_names
    assert_kind_of Array, names
    assert_includes names, name_a
    assert_includes names, name_b

    names.clear
    assert LingoFuse::P2PRegistration.registered?(name_a)
    assert LingoFuse::P2PRegistration.registered?(name_b)
  end

  def test_registered_names_empty_when_nothing_registered
    assert_kind_of Array, LingoFuse::P2PRegistration.registered_names
  end
end

# ======================================================================
# Top-level aliases
# ======================================================================

class TestP2PTopLevelAliases < P2PTestBase
  def test_top_level_register_p2p_call
    name = unique_api_name('alias_call')
    LingoFuse.register_p2p_call(name, 'desc') { |_i, _o| }
    @registered_names << name

    assert LingoFuse::P2PRegistration.registered?(name)
  end

  def test_top_level_register_p2p_notify
    name = unique_api_name('alias_notify')
    LingoFuse.register_p2p_notify(name, 'desc') { |_i| }
    @registered_names << name

    assert LingoFuse::P2PRegistration.registered?(name)
  end

  def test_top_level_unregister_p2p
    name = unique_api_name('alias_unreg')
    LingoFuse.register_p2p_call(name, 'desc') { |_i, _o| }

    result = LingoFuse.unregister_p2p(name)
    assert_equal true, result
    refute LingoFuse::P2PRegistration.registered?(name)
  end

  def test_top_level_unregister_p2p_unknown_returns_false
    name = unique_api_name('alias_unknown')
    assert_equal false, LingoFuse.unregister_p2p(name)
  end

  def test_top_level_methods_respond
    %i[register_p2p_call register_p2p_notify unregister_p2p].each do |m|
      assert_respond_to LingoFuse, m,
                        "LingoFuse must respond to #{m.inspect}"
    end
  end
end

# ======================================================================
# Registry lifetime and concurrency
# ======================================================================

class TestP2PRegistryLifetime < P2PTestBase
  def test_registry_isolation_from_app_bound_apis
    shared_name = unique_api_name('shared')

    register_call_tracked(shared_name)

    app = LingoFuse::AppHandle.new(
      unique_api_name('test_app'), 'isolation test'
    )
    begin
      app.register_call(shared_name, 'app-bound copy') { |_i, _o| }

      assert LingoFuse::P2PRegistration.registered?(shared_name)

      LingoFuse::P2PRegistration.unregister(shared_name)
      @registered_names.delete(shared_name)
      refute LingoFuse::P2PRegistration.registered?(shared_name)

      assert app.valid?
    ensure
      app.dispose
    end
  end

  def test_many_registrations_all_tracked
    names = (0...10).map { |i| unique_api_name("many_#{i}") }
    names.each { |n| register_call_tracked(n) }

    registered = LingoFuse::P2PRegistration.registered_names
    names.each do |n|
      assert_includes registered, n, "expected #{n.inspect} to be registered"
    end
  end

  # ------------------------------------------------------------------
  # Concurrency is capped at 4 threads to avoid scheduler-induced
  # flakiness. The watchdog guarantees a bounded test duration even
  # if the underlying layer misbehaves.
  #
  # QUEUE DRAIN DISCIPLINE
  # ----------------------
  # Both drain loops below guard `pop` with an explicit `empty?`
  # check on the same thread. The failure-message path uses `flunk`
  # after a guard, rather than embedding a `pop` inside an assertion
  # message: Ruby evaluates assertion arguments BEFORE the assertion
  # runs, so an embedded `pop` would execute even when there is
  # nothing to report.
  # ------------------------------------------------------------------

  def test_concurrent_registrations_do_not_corrupt_registry
    concurrency = 4
    names = (0...concurrency).map { |i| unique_api_name("conc_#{i}") }
    errors = Queue.new
    registered_locally = Queue.new

    threads = names.map do |n|
      Thread.new do
        LingoFuse::P2PRegistration.register_call(n, 'concurrent') do |_i, _o|
        end
        registered_locally << n
      rescue StandardError => e
        errors << e
      end
    end

    joined = threads.map { |t| t.join(5.0) }

    if joined.include?(nil)
      flunk 'concurrent registration did not complete within 5 s'
    end

    # Report any per-thread exceptions. The `errors.pop` call is
    # guarded by an explicit `empty?` check, so it can never block.
    unless errors.empty?
      flunk "concurrent registration raised: #{errors.pop.inspect}"
    end

    # Drain the success queue on the MAIN thread (single writer to
    # @registered_names, avoiding a concurrent Array mutation).
    until registered_locally.empty?
      @registered_names << registered_locally.pop
    end

    registered = LingoFuse::P2PRegistration.registered_names
    names.each do |n|
      assert_includes registered, n
    end
  end
end

# ======================================================================
# Callback wiring (requires the C extension)
# ======================================================================

class TestP2PCallbackWiring < P2PTestBase
  # ------------------------------------------------------------------
  # Dispatcher for the callback path.
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
        dispatcher.name = 'lingofuse-p2p-test-dispatcher' if dispatcher.respond_to?(:name=)
        sleep 0.05
      end
    end
  end

  def setup
    super
    skip 'lingofuse_ext not available' unless LingoFuse::NativeBridge.available?
    self.class.ensure_dispatcher!
  end

  # ------------------------------------------------------------------
  # Notify callback receives a handle argument
  # ------------------------------------------------------------------

  def test_notify_callback_receives_handle
    captured = Queue.new
    name = unique_api_name('wire_notify')

    LingoFuse::P2PRegistration.register_notify(name, 'wiring') do |input|
      captured << input
    end
    @registered_names << name

    ref_addr = lookup_ref_addr(name)
    skip 'internal ref lookup not available' if ref_addr.nil?

    outcome = run_with_timeout(3.0) do
      LingoFuse::NativeBridge.test_invoke_from_native_thread(
        ref_addr, 0xAA, nil, true
      )
    end

    if outcome == :timeout
      flunk 'test_invoke_from_native_thread did not return within 3 s ' \
            '(dispatcher may not be delivering the callback)'
    elsif outcome.is_a?(Array) && outcome.first == :error
      flunk "test_invoke_from_native_thread raised: #{outcome[1].inspect}"
    end

    delivered = wait_until(timeout_s: 1.0) { !captured.empty? }
    assert delivered, 'notify callback was never invoked'

    received = captured.pop
    assert_kind_of LingoFuse::DataHandle, received
  end

  # ------------------------------------------------------------------
  # Callback exception isolation
  # ------------------------------------------------------------------

  def test_notify_callback_exception_is_isolated
    captured = Queue.new
    name = unique_api_name('wire_notify_raise')

    LingoFuse::P2PRegistration.register_notify(name, 'wiring') do |_input|
      captured << :entered
      raise 'intentional failure from p2p wiring test'
    end
    @registered_names << name

    ref_addr = lookup_ref_addr(name)
    skip 'internal ref lookup not available' if ref_addr.nil?

    outcome = run_with_timeout(3.0) do
      LingoFuse::NativeBridge.test_invoke_from_native_thread(
        ref_addr, 0xBB, nil, true
      )
    end

    if outcome == :timeout
      flunk 'test_invoke_from_native_thread did not return within 3 s ' \
            '(dispatcher may not be delivering the callback)'
    elsif outcome.is_a?(Array) && outcome.first == :error
      flunk "test_invoke_from_native_thread raised: #{outcome[1].inspect}"
    end

    delivered = wait_until(timeout_s: 1.0) { !captured.empty? }
    assert delivered, 'notify callback was never invoked'
    assert_equal :entered, captured.pop
  end

  # ------------------------------------------------------------------
  # Internals
  # ------------------------------------------------------------------

  private

  def lookup_ref_addr(name)
    registry = LingoFuse::P2PRegistration.instance_variable_get(:@registry)
    return nil unless registry.is_a?(Hash)
    registry[name.to_s]
  end

  def wait_until(timeout_s:, interval_s: 0.01)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout_s
    loop do
      return true if yield
      return false if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
      sleep interval_s
    end
  end
end