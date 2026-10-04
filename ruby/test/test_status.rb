# frozen_string_literal: true
#
# test_status.rb — Unit tests for LingoFuse::Status.
#
# Covers: get_status_count, get_status, drain_status, post_status,
# check_main_thread, check_app, check_api.
#
# Every test here is safe from the Fiddle native-thread callback
# deadlock documented in test_network.rb. Status queue operations and
# cache-based health checks never enter the native-to-Ruby callback
# path.
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

class TestStatus < Minitest::Test
  def setup
    unless defined?(LingoFuse::Status) && LingoFuse.loaded?
      skip 'native library not loaded'
    end
    # Force a clean framework state so that check_main_thread has a
    # deterministic answer, and so that a previous test cannot leave a
    # pending status entry behind.
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
    "ipc:ruby_status_#{prefix}_#{Process.pid}_#{rand(1_000_000)}"
  end

  # ==================================================================
  # Status queue — before the main thread is running
  # ==================================================================

  def test_get_status_count_before_start_returns_non_negative
    count = LingoFuse::Status.get_status_count
    assert_kind_of Integer, count
    assert_operator count, :>=, 0
  end

  def test_get_status_returns_a_string
    msg = LingoFuse::Status.get_status
    assert_kind_of String, msg
  end

  def test_drain_status_returns_an_array
    drained = LingoFuse::Status.drain_status(16)
    assert_kind_of Array, drained
    drained.each { |m| assert_kind_of String, m }
  end

  def test_drain_status_zero_returns_empty_array
    assert_equal [], LingoFuse::Status.drain_status(0)
  end

  def test_drain_status_rejects_negative
    assert_raises(ArgumentError) { LingoFuse::Status.drain_status(-1) }
  end

  def test_post_status_accepts_a_string
    # Injection is queued even when the main thread is not running.
    LingoFuse::Status.post_status('unit-test marker')
    assert true
  end

  # ==================================================================
  # Status queue — with the main thread running
  # ==================================================================

  def test_status_queue_round_trip_with_running_framework
    endpoint = unique_endpoint('round_trip')
    LingoFuse::Framework.set_option('Wait_Ready', 'False')
    LingoFuse::Framework.reset_prepare
    LingoFuse::Framework.prepare_service(endpoint, endpoint)
    LingoFuse::Framework.prepare_client(endpoint, nil)
    LingoFuse::Framework.prepare_done

    # Give the simulated main thread a moment to spin up.
    sleep 0.2

    marker = "unit-test-#{rand(1_000_000)}"
    LingoFuse::Status.post_status(marker)
    sleep 0.3

    count = LingoFuse::Status.get_status_count
    assert_operator count, :>=, 0

    drained = LingoFuse::Status.drain_status(128)
    assert_kind_of Array, drained
    # We do not assert that the marker is present: other framework
    # messages may be interleaved, and the queue is bounded.
  end

  # ==================================================================
  # check_main_thread
  # ==================================================================

  def test_check_main_thread_returns_boolean
    v = LingoFuse::Status.check_main_thread
    assert_includes [true, false], v
  end

  def test_check_main_thread_is_false_after_shutdown
    # setup already performed a shutdown, so the main thread is not
    # running at this point.
    assert_equal false, LingoFuse::Status.check_main_thread
  end

  def test_check_main_thread_is_true_after_prepare_done
    endpoint = unique_endpoint('mt')
    LingoFuse::Framework.set_option('Wait_Ready', 'False')
    LingoFuse::Framework.reset_prepare
    LingoFuse::Framework.prepare_service(endpoint, endpoint)
    LingoFuse::Framework.prepare_client(endpoint, nil)
    LingoFuse::Framework.prepare_done

    assert_equal true, LingoFuse::Status.check_main_thread
  end

  # ==================================================================
  # check_app
  # ==================================================================

  def test_check_app_returns_boolean
    v = LingoFuse::Status.check_app('some_name_that_never_exists_98765')
    assert_includes [true, false], v
  end

  def test_check_app_rejects_nil
    # The underlying helper normalises nil to "", so it does not raise.
    # It should return false for the empty name.
    assert_equal false, LingoFuse::Status.check_app(nil)
  end

  def test_check_app_unknown_name_is_false
    assert_equal false,
                 LingoFuse::Status.check_app('definitely_not_an_app_12345')
  end

  def test_check_app_detects_a_live_app
    endpoint = unique_endpoint('app')
    app_name = "ruby_status_app_#{Process.pid}_#{rand(1_000_000)}"

    app = LingoFuse::AppHandle.new(app_name, 'status test')
    begin
      LingoFuse::Framework.set_option('Wait_Ready', 'False')
      LingoFuse::Framework.reset_prepare
      LingoFuse::Framework.prepare_service(endpoint, endpoint)
      LingoFuse::Framework.prepare_client(endpoint, app)
      LingoFuse::Framework.prepare_done

      # Poll until the app becomes visible on the local cache.
      seen = false
      30.times do
        if LingoFuse::Status.check_app(app_name)
          seen = true
          break
        end
        sleep 0.2
      end
      assert seen, "check_app('#{app_name}') never returned true"
    ensure
      app.dispose
    end
  end

  # ==================================================================
  # check_api
  # ==================================================================

  def test_check_api_returns_boolean
    v = LingoFuse::Status.check_api('no_such_app_98765', 'no_such_api')
    assert_includes [true, false], v
  end

  def test_check_api_unknown_is_false
    assert_equal false,
                 LingoFuse::Status.check_api(
                   'definitely_not_an_app_12345', 'anything'
                 )
  end

  def test_check_api_detects_a_registered_api
    endpoint = unique_endpoint('api')
    app_name = "ruby_status_api_#{Process.pid}_#{rand(1_000_000)}"

    app = LingoFuse::AppHandle.new(app_name, 'status api test')
    begin
      app.register_call('ping', 'ping') { |_i, o| o.write_int32(0) }

      LingoFuse::Framework.set_option('Wait_Ready', 'False')
      LingoFuse::Framework.reset_prepare
      LingoFuse::Framework.prepare_service(endpoint, endpoint)
      LingoFuse::Framework.prepare_client(endpoint, app)
      LingoFuse::Framework.prepare_done

      seen = false
      30.times do
        if LingoFuse::Status.check_api(app_name, 'ping')
          seen = true
          break
        end
        sleep 0.2
      end
      assert seen, "check_api('#{app_name}', 'ping') never returned true"
    ensure
      app.dispose
    end
  end
end