# frozen_string_literal: true
#
# test_framework.rb — Unit tests for the LingoFuse::Framework facade.
#
# Covers: reset_prepare, prepare_service, prepare_client, prepare_done,
# exit_main_thread, set_option, generate_app_name, get_app_name, call,
# try_call, notify, sequenced_notify, shutdown.
#
# ============================================================================
# SAFETY CONSTRAINT — READ BEFORE ADDING TESTS
# ============================================================================
# Ruby's Fiddle cannot marshal a native-thread callback onto the Ruby
# interpreter; MRI raises "[BUG] rb_thread_call_with_gvl() is called by
# non-ruby thread" and deadlocks. LingoFuse invokes every RECEIVED Call
# / Notify / Sequenced Notify on a native worker thread.
#
# Consequences for this file:
#
#   - `call` and `try_call` are only tested against a MISSING target.
#     The native layer then returns an empty handle without executing
#     any callback. A successful call to a live target would deadlock.
#
#   - `notify` and `sequenced_notify` are only tested for argument
#     validation. Sending a notification that reaches a live target
#     would deadlock for the same reason.
#
#   - `generate_app_name`, `get_app_name`, `set_option`, and the
#     prepare_* family never enter the callback path.
#
# See test_network.rb for the same constraint applied to the end-to-end
# integration suite.
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

class TestFramework < Minitest::Test
  def setup
    unless defined?(LingoFuse::Framework) && LingoFuse.loaded?
      skip 'native library not loaded'
    end
    quiet_shutdown
    LingoFuse::Framework.reset_prepare
  end

  def teardown
    quiet_shutdown
  end

  def quiet_shutdown
    begin
      LingoFuse::Framework.exit_main_thread
    rescue StandardError
      # ignored
    end
    begin
      LingoFuse::Framework.shutdown
    rescue StandardError
      # ignored
    end
  end

  def unique_endpoint(prefix)
    "ipc:ruby_fw_#{prefix}_#{Process.pid}_#{rand(1_000_000)}"
  end

  # ==================================================================
  # reset_prepare
  # ==================================================================

  def test_reset_prepare_does_not_raise
    LingoFuse::Framework.reset_prepare
    assert true
  end

  def test_reset_prepare_is_idempotent
    LingoFuse::Framework.reset_prepare
    LingoFuse::Framework.reset_prepare
    assert true
  end

  # ==================================================================
  # prepare_service / prepare_client / prepare_done
  # ==================================================================

  def test_prepare_service_returns_non_negative_tag
    endpoint = unique_endpoint('svc')
    tag = LingoFuse::Framework.prepare_service(endpoint, endpoint)
    assert_kind_of Integer, tag
    assert_operator tag, :>=, 0
  end

  def test_prepare_service_rejects_duplicate_address
    endpoint = unique_endpoint('svc_dup')
    LingoFuse::Framework.prepare_service(endpoint, endpoint)

    assert_raises(LingoFuse::Error) do
      LingoFuse::Framework.prepare_service(endpoint, endpoint)
    end
  end

  def test_prepare_client_with_nil_app
    endpoint = unique_endpoint('cli_nil')
    LingoFuse::Framework.prepare_service(endpoint, endpoint)
    tag = LingoFuse::Framework.prepare_client(endpoint, nil)
    assert_kind_of Integer, tag
    assert_operator tag, :>=, 0
  end

  def test_prepare_client_with_app_handle
    endpoint = unique_endpoint('cli_app')
    app = LingoFuse::AppHandle.new(
      "ruby_fw_app_#{Process.pid}_#{rand(1_000_000)}",
      'framework test'
    )
    begin
      LingoFuse::Framework.prepare_service(endpoint, endpoint)
      tag = LingoFuse::Framework.prepare_client(endpoint, app)
      assert_kind_of Integer, tag
      assert_operator tag, :>=, 0
    ensure
      app.dispose
    end
  end

  def test_prepare_client_rejects_non_handle_app
    endpoint = unique_endpoint('cli_bad')
    LingoFuse::Framework.prepare_service(endpoint, endpoint)
    assert_raises(ArgumentError) do
      LingoFuse::Framework.prepare_client(endpoint, 'not a handle')
    end
  end

  def test_prepare_done_returns_true_on_first_call
    endpoint = unique_endpoint('done_1')
    LingoFuse::Framework.set_option('Wait_Ready', 'False')
    LingoFuse::Framework.prepare_service(endpoint, endpoint)
    LingoFuse::Framework.prepare_client(endpoint, nil)

    assert_equal true, LingoFuse::Framework.prepare_done
  end

  def test_prepare_done_returns_false_on_second_call
    endpoint = unique_endpoint('done_2')
    LingoFuse::Framework.set_option('Wait_Ready', 'False')
    LingoFuse::Framework.prepare_service(endpoint, endpoint)
    LingoFuse::Framework.prepare_client(endpoint, nil)

    assert_equal true,  LingoFuse::Framework.prepare_done
    assert_equal false, LingoFuse::Framework.prepare_done
  end

  # ==================================================================
  # exit_main_thread / shutdown
  # ==================================================================

  def test_exit_main_thread_does_not_raise
    endpoint = unique_endpoint('exit')
    LingoFuse::Framework.set_option('Wait_Ready', 'False')
    LingoFuse::Framework.prepare_service(endpoint, endpoint)
    LingoFuse::Framework.prepare_client(endpoint, nil)
    LingoFuse::Framework.prepare_done

    LingoFuse::Framework.exit_main_thread
    assert true
  end

  def test_shutdown_is_idempotent
    LingoFuse::Framework.shutdown
    LingoFuse::Framework.shutdown
    assert true
  end

  # ==================================================================
  # set_option
  # ==================================================================

  def test_set_option_accepts_known_key
    LingoFuse::Framework.set_option('Wait_Ready', 'False')
    assert true
  end

  def test_set_option_accepts_unknown_key
    LingoFuse::Framework.set_option('ThisOptionDoesNotExist_xyz', 'value')
    assert true
  end

  def test_set_option_accepts_empty_strings
    LingoFuse::Framework.set_option('', '')
    assert true
  end

  def test_set_option_normalises_nil_via_helper
    # The helper converts nil to "", so this must not raise.
    LingoFuse::Framework.set_option(nil, nil)
    assert true
  end

  # ==================================================================
  # generate_app_name
  # ==================================================================

  def test_generate_app_name_returns_a_string
    endpoint = unique_endpoint('genname')
    LingoFuse::Framework.set_option('Wait_Ready', 'False')
    LingoFuse::Framework.prepare_service(endpoint, endpoint)
    LingoFuse::Framework.prepare_client(endpoint, nil)
    LingoFuse::Framework.prepare_done

    name = LingoFuse::Framework.generate_app_name
    assert_kind_of String, name
    refute_empty name
  end

  def test_generate_app_name_produces_distinct_values
    endpoint = unique_endpoint('genname_distinct')
    LingoFuse::Framework.set_option('Wait_Ready', 'False')
    LingoFuse::Framework.prepare_service(endpoint, endpoint)
    LingoFuse::Framework.prepare_client(endpoint, nil)
    LingoFuse::Framework.prepare_done

    names = Set.new
    5.times do
      names << LingoFuse::Framework.generate_app_name
      sleep 0.01
    end
    assert_operator names.size, :>=, 2,
                    'generate_app_name must produce distinct names'
  end

  # ==================================================================
  # get_app_name
  # ==================================================================

  def test_get_app_name_returns_constructor_name
    name = "ruby_fw_getname_#{Process.pid}_#{rand(1_000_000)}"
    app = LingoFuse::AppHandle.new(name, 'get_app_name test')
    begin
      assert_equal name, LingoFuse::Framework.get_app_name(app)
    ensure
      app.dispose
    end
  end

  def test_get_app_name_rejects_non_handle
    assert_raises(ArgumentError) do
      LingoFuse::Framework.get_app_name('not a handle')
    end
  end

  def test_get_app_name_rejects_disposed_handle
    app = LingoFuse::AppHandle.new(
      "ruby_fw_disposed_#{Process.pid}_#{rand(1_000_000)}",
      'disposed'
    )
    app.dispose

    assert_raises(LingoFuse::ObjectDisposedError) do
      LingoFuse::Framework.get_app_name(app)
    end
  end

  # ==================================================================
  # call — missing target only (see file header)
  # ==================================================================

  def test_call_to_missing_target_returns_size_zero_handle
    endpoint = unique_endpoint('call_missing')
    LingoFuse::Framework.set_option('Wait_Ready', 'False')
    LingoFuse::Framework.prepare_service(endpoint, endpoint)
    LingoFuse::Framework.prepare_client(endpoint, nil)
    LingoFuse::Framework.prepare_done

    req = LingoFuse::DataHandle.new('anything')
    begin
      res = LingoFuse::Framework.call('missing_app_xyz', req, 300)
      begin
        assert_equal 0, res.size
        assert res.valid?
      ensure
        res.dispose
      end
    ensure
      req.dispose
    end
  end

  def test_call_rejects_non_handle_param
    assert_raises(ArgumentError) do
      LingoFuse::Framework.call('app', 'not a handle', 100)
    end
  end

  def test_call_rejects_negative_timeout
    req = LingoFuse::DataHandle.new('x')
    begin
      assert_raises(ArgumentError) do
        LingoFuse::Framework.call('app', req, -1)
      end
    ensure
      req.dispose
    end
  end

  def test_call_rejects_disposed_param
    req = LingoFuse::DataHandle.new('x')
    req.dispose
    assert_raises(LingoFuse::ObjectDisposedError) do
      LingoFuse::Framework.call('app', req, 100)
    end
  end

  # ==================================================================
  # try_call — missing target only
  # ==================================================================

  def test_try_call_to_missing_target_returns_nil
    endpoint = unique_endpoint('try_missing')
    LingoFuse::Framework.set_option('Wait_Ready', 'False')
    LingoFuse::Framework.prepare_service(endpoint, endpoint)
    LingoFuse::Framework.prepare_client(endpoint, nil)
    LingoFuse::Framework.prepare_done

    req = LingoFuse::DataHandle.new('anything')
    begin
      res = LingoFuse::Framework.try_call('missing_app_xyz', req, 300)
      assert_nil res
    ensure
      req.dispose
    end
  end

  def test_try_call_rejects_non_handle_param
    assert_raises(ArgumentError) do
      LingoFuse::Framework.try_call('app', 'not a handle', 100)
    end
  end

  # ==================================================================
  # notify / sequenced_notify — argument validation only
  # ==================================================================

  def test_notify_rejects_non_handle_param
    assert_raises(ArgumentError) do
      LingoFuse::Framework.notify('app', 'not a handle')
    end
  end

  def test_notify_rejects_disposed_param
    req = LingoFuse::DataHandle.new('x')
    req.dispose
    assert_raises(LingoFuse::ObjectDisposedError) do
      LingoFuse::Framework.notify('app', req)
    end
  end

  def test_sequenced_notify_rejects_non_handle_param
    assert_raises(ArgumentError) do
      LingoFuse::Framework.sequenced_notify('app', 'not a handle')
    end
  end

  def test_sequenced_notify_rejects_disposed_param
    req = LingoFuse::DataHandle.new('x')
    req.dispose
    assert_raises(LingoFuse::ObjectDisposedError) do
      LingoFuse::Framework.sequenced_notify('app', req)
    end
  end
end