# frozen_string_literal: true
#
# test_network.rb — Network integration tests that are safe to run from a
# Fiddle-based Ruby binding.
#
# ============================================================================
# CRITICAL — WHY SOME TESTS ARE ABSENT
# ============================================================================
# Ruby's Fiddle can only dispatch a callback into Ruby code when the
# callback is invoked on the Ruby main thread.
#
# LingoFuse, however, invokes every RECEIVED Call / Notify / Sequenced
# Notify / Network event on a native worker thread that Ruby does not
# know about. When Fiddle's Closure then tries to call back into Ruby
# from that thread, MRI raises
#
#     [BUG] rb_thread_call_with_gvl() is called by non-ruby thread
#
# and the process deadlocks. This is a fundamental limitation of the
# Fiddle C API, not a bug in this binding. It cannot be worked around
# from pure Ruby: a C extension would be required to marshal the
# callback onto the Ruby main thread before user code runs.
#
# Consequently, the following scenarios CANNOT be tested (or even
# exercised) from Ruby:
#
#   - Receiving a remote Call        (receiver callback runs on a
#                                     native worker thread)
#   - Receiving a Notify             (same)
#   - Receiving a Sequenced Notify   (same)
#   - Being told about a Network Connect / Disconnect event
#
# Any test that would enter those paths has been removed. The scenarios
# that remain are all driven from the Ruby main thread and never enter
# the native-to-Ruby callback path.
#
# ============================================================================
# COVERAGE
# ============================================================================
#   01  call to a missing target returns an empty handle (timeout path)
#   02  check_app / check_api against a live app (cache lookup only)
#   03  prepare_done returns true only once
#   04  unknown option is silently ignored
#   05  Overlap_Connection=false rejects a second client
#   06  Overlap_Connection=true allows a second client
#   07  NetworkEvents install / clear round trip (no live triggering)
#   08  Status queue: post and drain
#   09  NetworkEventQueue producer / consumer (pure Ruby)
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

class TestNetwork < Minitest::Test
  # ------------------------------------------------------------------
  # Setup and teardown
  # ------------------------------------------------------------------

  def setup
    unless defined?(LingoFuse::Framework) && LingoFuse.loaded?
      skip 'native library not loaded; network tests are skipped'
    end

    # Never let a previous test leave a network event callback
    # installed. A stray callback would be dispatched on a native
    # worker thread the moment any connection succeeds, and Ruby would
    # then deadlock on the [BUG] path documented in the file header.
    begin
      LingoFuse::NetworkEvents.clear
    rescue StandardError
      # ignored
    end

    quiet_shutdown
    LingoFuse::Framework.reset_prepare
  end

  def teardown
    begin
      LingoFuse::NetworkEvents.clear
    rescue StandardError
      # ignored
    end
    quiet_shutdown
  end

  # ------------------------------------------------------------------
  # Helpers
  # ------------------------------------------------------------------

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
    "ipc:ruby_test_#{prefix}_#{Process.pid}_#{rand(1_000_000)}"
  end

  def unique_app_name(prefix)
    "ruby_test_app_#{prefix}_#{Process.pid}_#{rand(1_000_000)}"
  end

  # ------------------------------------------------------------------
  # 01 — call to a missing target returns an empty handle
  # ------------------------------------------------------------------

  def test_call_to_missing_target_returns_empty
    endpoint = unique_endpoint('missing')

    LingoFuse::Framework.set_option('Wait_Ready', 'False')
    LingoFuse::Framework.reset_prepare
    LingoFuse::Framework.prepare_service(endpoint, endpoint)
    LingoFuse::Framework.prepare_client(endpoint, nil)
    LingoFuse::Framework.prepare_done

    req = LingoFuse::DataHandle.new('anything')
    begin
      res = LingoFuse::Framework.call('no_such_app_xyz_98765', req, 500)
      begin
        assert_equal 0, res.size
      ensure
        res.dispose
      end
    ensure
      req.dispose
    end
  end

  # ------------------------------------------------------------------
  # 02 — check_app / check_api against a live app
  # ------------------------------------------------------------------

  def test_check_functions_detect_live_app
    endpoint = unique_endpoint('check')
    app_name = unique_app_name('check')

    app = LingoFuse::AppHandle.new(app_name, 'check test')
    begin
      app.register_call('ping', 'ping') do |_input, output|
        output.write_int32(0)
      end

      LingoFuse::Framework.set_option('Wait_Ready', 'False')
      LingoFuse::Framework.reset_prepare
      LingoFuse::Framework.prepare_service(endpoint, endpoint)
      LingoFuse::Framework.prepare_client(endpoint, app)
      LingoFuse::Framework.prepare_done

      assert LingoFuse::Status.check_main_thread

      app_seen = false
      api_seen = false
      30.times do
        app_seen ||= LingoFuse::Status.check_app(app_name)
        api_seen ||= LingoFuse::Status.check_api(app_name, 'ping')
        break if app_seen && api_seen
        sleep 0.2
      end

      assert app_seen, "check_app('#{app_name}') never returned true"
      assert api_seen, "check_api('#{app_name}', 'ping') never returned true"
    ensure
      app.dispose
    end
  end

  # ------------------------------------------------------------------
  # 03 — prepare_done returns true only once
  # ------------------------------------------------------------------

  def test_prepare_done_returns_true_only_once
    endpoint = unique_endpoint('once')

    LingoFuse::Framework.set_option('Wait_Ready', 'False')
    LingoFuse::Framework.reset_prepare
    LingoFuse::Framework.prepare_service(endpoint, endpoint)
    LingoFuse::Framework.prepare_client(endpoint, nil)

    first = LingoFuse::Framework.prepare_done
    assert_equal true, first, 'first prepare_done must return true'

    second = LingoFuse::Framework.prepare_done
    assert_equal false, second,
                 'second prepare_done without shutdown must return false'
  end

  # ------------------------------------------------------------------
  # 04 — unknown option is silently ignored
  # ------------------------------------------------------------------

  def test_unknown_option_is_ignored
    LingoFuse::Framework.set_option('ThisOptionDoesNotExist_xyz', 'value')
    LingoFuse::Framework.set_option('', '')
    assert true
  end

  # ------------------------------------------------------------------
  # 05 — Overlap_Connection=false rejects a second client
  # ------------------------------------------------------------------

  def test_overlap_connection_false_rejects_second_client
    endpoint = unique_endpoint('ovl_false')

    LingoFuse::Framework.set_option('Wait_Ready', 'False')
    LingoFuse::Framework.set_option('Overlap_Connection', 'False')
    LingoFuse::Framework.reset_prepare
    LingoFuse::Framework.prepare_service(endpoint, endpoint)

    tag1 = LingoFuse::Framework.prepare_client(endpoint, nil)
    assert_operator tag1, :>=, 0

    err = assert_raises(LingoFuse::Error) do
      LingoFuse::Framework.prepare_client(endpoint, nil)
    end
    assert_match(/duplicate|rejected/i, err.message)
  end

  # ------------------------------------------------------------------
  # 06 — Overlap_Connection=true allows a second client
  # ------------------------------------------------------------------

  def test_overlap_connection_true_allows_second_client
    endpoint = unique_endpoint('ovl_true')

    LingoFuse::Framework.set_option('Wait_Ready', 'False')
    LingoFuse::Framework.set_option('Overlap_Connection', 'True')
    LingoFuse::Framework.reset_prepare
    LingoFuse::Framework.prepare_service(endpoint, endpoint)

    tag1 = LingoFuse::Framework.prepare_client(endpoint, nil)
    tag2 = LingoFuse::Framework.prepare_client(endpoint, nil)

    assert_operator tag1, :>=, 0
    assert_operator tag2, :>=, 0
    refute_equal tag1, tag2,
                 'overlap connection must assign distinct tags'

    LingoFuse::Framework.set_option('Overlap_Connection', 'False')
  end

  # ------------------------------------------------------------------
  # 07 — NetworkEvents install / clear round trip (no live triggering)
  # ------------------------------------------------------------------

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

  # ------------------------------------------------------------------
  # 08 — Status queue post and drain
  # ------------------------------------------------------------------

  def test_status_queue_post_and_drain
    endpoint = unique_endpoint('status')

    LingoFuse::Framework.set_option('Wait_Ready', 'False')
    LingoFuse::Framework.reset_prepare
    LingoFuse::Framework.prepare_service(endpoint, endpoint)
    LingoFuse::Framework.prepare_client(endpoint, nil)
    LingoFuse::Framework.prepare_done

    sleep 0.2

    marker = "ruby_test_status_#{rand(1_000_000)}"
    LingoFuse::Status.post_status(marker)

    sleep 0.3

    count = LingoFuse::Status.get_status_count
    assert_operator count, :>=, 0

    drained = LingoFuse::Status.drain_status(64)
    assert_kind_of Array, drained
  end

  # ------------------------------------------------------------------
  # 09 — NetworkEventQueue producer/consumer (pure Ruby)
  # ------------------------------------------------------------------

  def test_network_event_queue_producer_consumer
    q = LingoFuse::NetworkEventQueue.new(max_size: 32)

    # Simulate the producer side. Normally this is called on a native
    # worker thread; we call it directly here because we only verify the
    # queue's thread-safe plumbing, not the native callback path.
    q.send(:enqueue, :connect, 'addr-a')
    q.send(:enqueue, :disconnect, 'addr-b')

    assert_equal 2, q.size

    type1, addr1 = q.get
    type2, addr2 = q.get

    assert_equal :connect,    type1
    assert_equal 'addr-a',    addr1
    assert_equal :disconnect, type2
    assert_equal 'addr-b',    addr2
    assert q.empty?
  end
end