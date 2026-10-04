# frozen_string_literal: true
#
# test_app_handle.rb — Unit tests for the LingoFuse::AppHandle wrapper.
#
# ============================================================================
# COVERAGE
# ============================================================================
#   - Construction and identity
#   - Call API registration and local invocation
#   - Notify API registration and local delivery
#   - Duplicate registration rejection
#   - Unregister and re-register
#   - Case-insensitive API matching
#   - Callback exception isolation
#   - Callback lifetime / callback registry
#   - Dispose semantics and use-after-dispose
#   - NetworkEventListener base class (module-level API smoke test)
#   - NetworkEventQueue producer/consumer
#
# ============================================================================

require 'minitest/autorun'

_lib_dir = File.expand_path('../lib', __dir__)
$LOAD_PATH.unshift(_lib_dir) unless $LOAD_PATH.include?(_lib_dir)

begin
  require 'lingofuse'
rescue StandardError, LoadError => e
  warn "Failed to load LingoFuse: #{e.class}: #{e.message}"
end

class TestAppHandle < Minitest::Test
  def setup
    unless defined?(LingoFuse::AppHandle) && defined?(LingoFuse::DataHandle) &&
           LingoFuse.loaded?
      skip 'native library not loaded; AppHandle tests are skipped'
    end
  end

  # ------------------------------------------------------------------
  # Helpers
  # ------------------------------------------------------------------

  def unique_name(prefix)
    "#{prefix}_#{Process.pid}_#{rand(1_000_000)}"
  end

  def with_app(prefix = 'ta')
    name = unique_name(prefix)
    app = LingoFuse::AppHandle.new(name, 'test app')
    return app unless block_given?
    begin
      yield app
    ensure
      app.dispose
    end
  end

  # ==================================================================
  # Construction and identity
  # ==================================================================

  def test_new_creates_valid_handle
    with_app do |app|
      assert app.valid?
      refute_nil app.raw
      refute(app.raw.respond_to?(:to_i) && app.raw.to_i.zero?)
    end
  end

  def test_name_returns_constructor_argument
    name = unique_name('named')
    app = LingoFuse::AppHandle.new(name, 'desc')
    begin
      assert_equal name, app.name
    ensure
      app.dispose
    end
  end

  def test_new_accepts_empty_description
    with_app do |app|
      assert app.valid?
    end
  end

  def test_new_raises_on_nil_name
    assert_raises(ArgumentError) do
      LingoFuse::AppHandle.new(nil)
    end
  end

  # ==================================================================
  # Call API registration and local invocation
  # ==================================================================

  def test_register_call_succeeds
    with_app do |app|
      ok = app.register_call('add', 'add') do |_input, _output|
        # no-op
      end
      assert_equal true, ok
    end
  end

  def test_local_call_roundtrip
    with_app do |app|
      app.register_call('add', 'add') do |input, output|
        a = input.read_int32
        b = input.read_int32
        output.write_int32(a + b)
      end

      req = LingoFuse::DataHandle.new('add')
      begin
        req.write_int32(5)
        req.write_int32(7)
        res = app.local_call(req)
        begin
          assert_equal 12, res.read_int32
        ensure
          res.dispose
        end
      ensure
        req.dispose
      end
    end
  end

  def test_local_call_on_missing_api_returns_empty
    with_app do |app|
      req = LingoFuse::DataHandle.new('does_not_exist')
      begin
        res = app.local_call(req)
        begin
          assert_equal 0, res.size
        ensure
          res.dispose
        end
      ensure
        req.dispose
      end
    end
  end

  # ==================================================================
  # Notify API registration and local delivery
  # ==================================================================

  def test_register_notify_succeeds
    with_app do |app|
      ok = app.register_notify('log', 'log') do |_input|
        # no-op
      end
      assert_equal true, ok
    end
  end

  def test_local_notify_delivers_payload
    with_app do |app|
      received = []
      app.register_notify('sink', 'sink') do |input|
        received << input.read_string
      end

      req = LingoFuse::DataHandle.new('sink')
      begin
        req.write_string('hello')
        app.local_notify(req)
      ensure
        req.dispose
      end

      assert_equal ['hello'], received
    end
  end

  # ==================================================================
  # Duplicate registration
  # ==================================================================

  def test_duplicate_registration_raises
    with_app do |app|
      app.register_call('dup', 'first') { |_i, _o| }
      err = assert_raises(LingoFuse::RegistrationError) do
        app.register_call('dup', 'second') { |_i, _o| }
      end
      assert_equal 'dup', err.api_name
    end
  end

  def test_duplicate_notify_registration_raises
    with_app do |app|
      app.register_notify('dup', 'first') { |_i| }
      assert_raises(LingoFuse::RegistrationError) do
        app.register_notify('dup', 'second') { |_i| }
      end
    end
  end

  # ==================================================================
  # Unregister and re-register
  # ==================================================================

  def test_unregister_returns_true_and_allows_reregister
    with_app do |app|
      app.register_call('hot', 'v1') do |_input, output|
        output.write_int32(1)
      end

      assert_equal true, app.unregister('hot')

      app.register_call('hot', 'v2') do |_input, output|
        output.write_int32(2)
      end

      req = LingoFuse::DataHandle.new('hot')
      begin
        res = app.local_call(req)
        begin
          assert_equal 2, res.read_int32
        ensure
          res.dispose
        end
      ensure
        req.dispose
      end
    end
  end

  def test_unregister_returns_false_for_unknown_api
    with_app do |app|
      assert_equal false, app.unregister('nonexistent')
    end
  end

  # ==================================================================
  # Case-insensitive matching
  # ==================================================================

  def test_api_name_matching_is_case_insensitive
    with_app do |app|
      app.register_call('MixedCase', 'desc') do |_input, output|
        output.write_int32(99)
      end

      req = LingoFuse::DataHandle.new('mixedcase')
      begin
        res = app.local_call(req)
        begin
          assert_equal 99, res.read_int32
        ensure
          res.dispose
        end
      ensure
        req.dispose
      end
    end
  end

  def test_unregister_is_case_insensitive
    with_app do |app|
      app.register_call('MixedCase', 'desc') { |_i, _o| }
      assert_equal true, app.unregister('MIXEDCASE')
    end
  end

  # ==================================================================
  # Callback exception isolation
  # ==================================================================

  def test_callback_exception_does_not_propagate
    with_app do |app|
      app.register_call('boom', 'always raises') do |_input, _output|
        raise 'intentional failure for isolation test'
      end

      req = LingoFuse::DataHandle.new('boom')
      begin
        res = app.local_call(req)
        begin
          assert_equal 0, res.size
        ensure
          res.dispose
        end
      ensure
        req.dispose
      end
    end
  end

  def test_callback_exception_is_reported
    with_app do |app|
      captured = []
      original = LingoFuse::CallbackErrorReporter.handler
      LingoFuse::CallbackErrorReporter.handler = lambda do |source, error|
        captured << [source, error.class, error.message]
      end

      begin
        app.register_call('boom', 'always raises') do |_input, _output|
          raise ArgumentError, 'oops'
        end

        req = LingoFuse::DataHandle.new('boom')
        begin
          res = app.local_call(req)
          res.dispose
        ensure
          req.dispose
        end
      ensure
        LingoFuse::CallbackErrorReporter.handler = original
      end

      assert_equal 1, captured.size
      source, klass, message = captured.first
      assert_includes source, 'boom'
      assert_equal ArgumentError, klass
      assert_equal 'oops', message
    end
  end

  # ==================================================================
  # Callback registry — the GC-callback UAF prevention
  # ==================================================================

  def test_callback_registry_releases_on_unregister
    with_app do |app|
      app.register_call('temp', 'temp') { |_i, _o| }
      registry = app.instance_variable_get(:@closures)
      assert registry.key?('temp'), 'callback must be registered'

      app.unregister('temp')
      refute registry.key?('temp'),
             'unregister must remove the callback from the registry'
    end
  end

  def test_callback_registry_releases_on_dispose
    name = unique_name('dispose_reg')
    app = LingoFuse::AppHandle.new(name)
    app.register_call('keep', 'keep') { |_i, _o| }
    registry = app.instance_variable_get(:@closures)
    refute registry.empty?

    app.dispose
    assert registry.empty?,
           'dispose must clear the callback registry'
  end

  def test_duplicate_registration_does_not_leak_a_registry_entry
    with_app do |app|
      app.register_call('dup', 'first') { |_i, _o| }
      registry = app.instance_variable_get(:@closures)
      size_before = registry.size

      assert_raises(LingoFuse::RegistrationError) do
        app.register_call('dup', 'second') { |_i, _o| }
      end

      assert_equal size_before, registry.size,
                   'a rejected registration must not change the registry'
    end
  end

  # ==================================================================
  # Lifetime
  # ==================================================================

  def test_dispose_is_idempotent
    name = unique_name('idem')
    app = LingoFuse::AppHandle.new(name)
    app.dispose
    app.dispose
    app.dispose
    refute app.valid?
  end

  def test_use_after_dispose_raises
    name = unique_name('uad')
    app = LingoFuse::AppHandle.new(name)
    app.dispose

    assert_raises(LingoFuse::ObjectDisposedError) do
      app.register_call('x', 'x') { |_i, _o| }
    end
    assert_raises(LingoFuse::ObjectDisposedError) do
      app.register_notify('x', 'x') { |_i| }
    end
    assert_raises(LingoFuse::ObjectDisposedError) { app.unregister('x') }
    assert_raises(LingoFuse::ObjectDisposedError) { app.bind }
  end

  # ==================================================================
  # Argument validation
  # ==================================================================

  def test_register_call_requires_block
    with_app do |app|
      assert_raises(ArgumentError) do
        app.register_call('no_block', 'desc')
      end
    end
  end

  def test_register_notify_requires_block
    with_app do |app|
      assert_raises(ArgumentError) do
        app.register_notify('no_block', 'desc')
      end
    end
  end

  def test_local_call_requires_data_handle
    with_app do |app|
      assert_raises(ArgumentError) { app.local_call('not a handle') }
    end
  end

  def test_local_notify_requires_data_handle
    with_app do |app|
      assert_raises(ArgumentError) { app.local_notify('not a handle') }
    end
  end

  # ==================================================================
  # NetworkEvents module smoke test
  # ==================================================================

  def test_network_events_module_is_loaded
    assert defined?(LingoFuse::NetworkEvents)
    assert LingoFuse::NetworkEvents.respond_to?(:set)
    assert LingoFuse::NetworkEvents.respond_to?(:clear)
    assert LingoFuse::NetworkEvents.respond_to?(:installed?)
  end

  def test_network_events_install_and_clear
    LingoFuse::NetworkEvents.clear
    refute LingoFuse::NetworkEvents.installed?

    LingoFuse::NetworkEvents.set(
      on_connect:    ->(_addr) {},
      on_disconnect: ->(_addr) {}
    )
    assert LingoFuse::NetworkEvents.installed?

    LingoFuse::NetworkEvents.clear
    refute LingoFuse::NetworkEvents.installed?
  end

  def test_network_events_rejects_non_callable
    assert_raises(ArgumentError) do
      LingoFuse::NetworkEvents.set(on_connect: 'not callable')
    end
  end

  def test_network_event_listener_base_class_is_usable
    assert defined?(LingoFuse::NetworkEventListener)
    listener = LingoFuse::NetworkEventListener.new
    assert_nil listener.on_connect('addr')
    assert_nil listener.on_disconnect('addr')
  end

  # ==================================================================
  # NetworkEventQueue producer/consumer
  # ==================================================================

  def test_network_event_queue_basic_enqueue_dequeue
    q = LingoFuse::NetworkEventQueue.new(max_size: 16)
    q.send(:enqueue, :connect, 'addr1')
    q.send(:enqueue, :disconnect, 'addr2')

    assert_equal 2, q.size
    assert_equal [:connect, 'addr1'],    q.get
    assert_equal [:disconnect, 'addr2'], q.get
    assert q.empty?
  end

  def test_network_event_queue_get_raises_on_timeout
    q = LingoFuse::NetworkEventQueue.new(max_size: 4)
    assert_raises(ThreadError) { q.get(timeout: 0.05) }
  end

  def test_network_event_queue_clear
    q = LingoFuse::NetworkEventQueue.new(max_size: 4)
    q.send(:enqueue, :connect, 'a')
    q.send(:enqueue, :connect, 'b')
    q.clear
    assert q.empty?
  end
end