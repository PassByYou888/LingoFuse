# frozen_string_literal: true
#
# test_app_handle_extra.rb — Additional boundary tests for AppHandle.
#
# These complement test_app_handle.rb. All tests require the native
# library.
#

require 'minitest/autorun'

_lib_dir = File.expand_path('../lib', __dir__)
$LOAD_PATH.unshift(_lib_dir) unless $LOAD_PATH.include?(_lib_dir)

begin
  require 'lingofuse'
rescue StandardError, LoadError => e
  warn "Failed to load LingoFuse: #{e.class}: #{e.message}"
end

class TestAppHandleExtra < Minitest::Test
  def setup
    unless defined?(LingoFuse::AppHandle) && LingoFuse.loaded?
      skip 'native library not loaded'
    end
  end

  def unique_name(prefix)
    "#{prefix}_#{Process.pid}_#{rand(1_000_000)}"
  end

  def with_app(prefix = 'extra')
    app = LingoFuse::AppHandle.new(unique_name(prefix), 'extra test')
    return app unless block_given?
    begin
      yield app
    ensure
      app.dispose
    end
  end

  # ==================================================================
  # bind() — no client prepared
  # ==================================================================

  def test_bind_returns_zero_when_no_client_prepared
    with_app do |app|
      app.register_call('ping', 'ping') { |_i, o| o.write_int32(0) }
      assert_equal 0, app.bind
    end
  end

  # ==================================================================
  # local_notify to an unregistered API
  # ==================================================================

  def test_local_notify_to_unregistered_api_is_a_silent_noop
    with_app do |app|
      req = LingoFuse::DataHandle.new('does_not_exist')
      begin
        app.local_notify(req)
      ensure
        req.dispose
      end
      assert true
    end
  end

  # ==================================================================
  # local_call to an unregistered API returns an empty handle
  # ==================================================================

  def test_local_call_to_unregistered_api_returns_empty_handle
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
  # Callback registry content
  # ==================================================================

  def test_registry_keys_are_lowercased
    with_app do |app|
      app.register_call('MixedCase', 'desc') { |_i, _o| }
      registry = app.instance_variable_get(:@closures)
      assert registry.key?('mixedcase'),
             "expected registry key 'mixedcase', got: #{registry.keys.inspect}"
      refute registry.key?('MixedCase')
    end
  end

  def test_registry_contains_one_closure_per_api
    with_app do |app|
      app.register_call('a', 'a') { |_i, _o| }
      app.register_call('b', 'b') { |_i, _o| }
      app.register_notify('c', 'c') { |_i| }

      registry = app.instance_variable_get(:@closures)
      assert_equal 3, registry.size
      assert registry.key?('a')
      assert registry.key?('b')
      assert registry.key?('c')
    end
  end

  # ==================================================================
  # Duplicate register — registry must not leak
  # ==================================================================

  def test_rejected_registration_does_not_change_registry_size
    with_app do |app|
      app.register_call('dup', 'first') { |_i, _o| }
      registry = app.instance_variable_get(:@closures)
      size_before = registry.size

      assert_raises(LingoFuse::RegistrationError) do
        app.register_call('dup', 'second') { |_i, _o| }
      end

      assert_equal size_before, registry.size
    end
  end

  # ==================================================================
  # Unregister on a non-existent API
  # ==================================================================

  def test_unregister_nonexistent_returns_false
    with_app do |app|
      assert_equal false, app.unregister('never_registered')
    end
  end

  # ==================================================================
  # Re-register after unregister with the same name
  # ==================================================================

  def test_reregister_produces_a_new_closure
    with_app do |app|
      app.register_call('hot', 'v1') { |_i, _o| }
      registry = app.instance_variable_get(:@closures)
      first_closure = registry['hot']
      refute_nil first_closure

      app.unregister('hot')
      refute registry.key?('hot')

      app.register_call('hot', 'v2') { |_i, _o| }
      second_closure = registry['hot']
      refute_nil second_closure
      refute_same first_closure, second_closure
    end
  end

  # ==================================================================
  # Dispose clears the registry
  # ==================================================================

  def test_dispose_clears_the_registry
    app = LingoFuse::AppHandle.new(unique_name('dispose'))
    app.register_call('a', 'a') { |_i, _o| }
    app.register_notify('b', 'b') { |_i| }
    registry = app.instance_variable_get(:@closures)
    refute registry.empty?

    app.dispose
    assert registry.empty?
  end

  # ==================================================================
  # Multiple sequential apps
  # ==================================================================

  def test_multiple_sequential_apps_do_not_interfere
    5.times do |i|
      app = LingoFuse::AppHandle.new(unique_name("seq#{i}"), 'seq')
      begin
        app.register_call('echo', 'echo') do |input, output|
          output.write_string(input.read_string)
        end

        req = LingoFuse::DataHandle.new('echo')
        begin
          req.write_string("msg-#{i}")
          res = app.local_call(req)
          begin
            assert_equal "msg-#{i}", res.read_string
          ensure
            res.dispose
          end
        ensure
          req.dispose
        end
      ensure
        app.dispose
      end
    end
  end

  # ==================================================================
  # Argument validation
  # ==================================================================

  def test_new_with_nil_name_raises
    assert_raises(ArgumentError) do
      LingoFuse::AppHandle.new(nil)
    end
  end

  def test_new_with_numeric_name_is_accepted
    app = LingoFuse::AppHandle.new(unique_name('num'), 'numeric')
    begin
      assert app.valid?
    ensure
      app.dispose
    end
  end

  def test_local_call_with_a_string_raises
    with_app do |app|
      assert_raises(ArgumentError) { app.local_call('not a handle') }
    end
  end

  def test_local_notify_with_nil_raises
    with_app do |app|
      assert_raises(ArgumentError) { app.local_notify(nil) }
    end
  end

  # ==================================================================
  # Callback raising a non-StandardError exception
  # ==================================================================

  def test_callback_raising_a_non_standard_exception_is_isolated
    with_app do |app|
      app.register_call('boom', 'raises Exception') do |_i, _o|
        raise Exception, 'non-standard' # rubocop:disable Lint/RaiseException
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
end