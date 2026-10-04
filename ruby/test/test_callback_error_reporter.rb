# frozen_string_literal: true
#
# test_callback_error_reporter.rb — Unit tests for CallbackErrorReporter.
#
# This file does NOT require the native library. The reporter is pure
# Ruby: it holds a handler and dispatches reports to it.
#
# ============================================================================
# WHY THE REQUIRE PATH CHANGED
# ============================================================================
# CallbackErrorReporter used to be defined inside app_handle.rb. It now
# lives in its own file, callback_error_reporter.rb, so that
# native_bridge.rb can require it without pulling in app_handle.rb
# (which would create a require cycle).
#
# This test therefore requires callback_error_reporter directly. It
# does NOT require app_handle, so it remains independent of the
# native library and of the C extension.
#
# ============================================================================

require 'minitest/autorun'
require 'stringio'

_lib_dir = File.expand_path('../lib', __dir__)
$LOAD_PATH.unshift(_lib_dir) unless $LOAD_PATH.include?(_lib_dir)

require_relative '../lib/lingofuse/errors'
require_relative '../lib/lingofuse/callback_error_reporter'

class TestCallbackErrorReporter < Minitest::Test
  def setup
    # Preserve any pre-existing handler so tests do not interfere with a
    # caller's configuration.
    @original_handler = LingoFuse::CallbackErrorReporter.handler
    LingoFuse::CallbackErrorReporter.handler = nil
  end

  def teardown
    LingoFuse::CallbackErrorReporter.handler = @original_handler
  end

  # ------------------------------------------------------------------
  # Handler installation
  # ------------------------------------------------------------------

  def test_default_handler_is_nil
    LingoFuse::CallbackErrorReporter.handler = nil
    assert_nil LingoFuse::CallbackErrorReporter.handler
  end

  def test_handler_accepts_a_callable
    h = ->(_src, _err) {}
    LingoFuse::CallbackErrorReporter.handler = h
    assert_same h, LingoFuse::CallbackErrorReporter.handler
  end

  def test_handler_accepts_a_proc
    h = proc { |_src, _err| }
    LingoFuse::CallbackErrorReporter.handler = h
    assert_same h, LingoFuse::CallbackErrorReporter.handler
  end

  def test_handler_rejects_a_non_callable
    assert_raises(ArgumentError) do
      LingoFuse::CallbackErrorReporter.handler = 'not callable'
    end
  end

  def test_handler_accepts_nil
    LingoFuse::CallbackErrorReporter.handler = nil
    assert_nil LingoFuse::CallbackErrorReporter.handler
  end

  # ------------------------------------------------------------------
  # report dispatch
  # ------------------------------------------------------------------

  def test_report_invokes_the_installed_handler
    captured = nil
    LingoFuse::CallbackErrorReporter.handler = ->(src, err) do
      captured = [src, err]
    end

    err = RuntimeError.new('boom')
    LingoFuse::CallbackErrorReporter.report('my.source', err)

    refute_nil captured
    assert_equal 'my.source', captured[0]
    assert_same err, captured[1]
  end

  def test_report_swallows_handler_exception
    LingoFuse::CallbackErrorReporter.handler = ->(_src, _err) do
      raise 'handler itself failed'
    end

    LingoFuse::CallbackErrorReporter.report('source', RuntimeError.new('x'))
    assert true
  end

  def test_report_without_handler_writes_to_stderr
    LingoFuse::CallbackErrorReporter.handler = nil

    original = $stderr
    captured = StringIO.new
    $stderr = captured

    begin
      LingoFuse::CallbackErrorReporter.report(
        'my.source',
        RuntimeError.new('boom')
      )
    ensure
      $stderr = original
    end

    output = captured.string
    assert_includes output, 'my.source'
    assert_includes output, 'boom'
    assert_includes output, 'RuntimeError'
  end

  def test_report_accepts_non_exception_payloads
    captured = nil
    LingoFuse::CallbackErrorReporter.handler = ->(src, err) do
      captured = [src, err]
    end

    LingoFuse::CallbackErrorReporter.report('src', 'a plain string')
    assert_equal 'a plain string', captured[1]
  end

  # ------------------------------------------------------------------
  # Concurrency safety
  # ------------------------------------------------------------------

  def test_handler_can_be_swapped_concurrently
    LingoFuse::CallbackErrorReporter.handler = ->(_s, _e) {}

    threads = []
    10.times do
      threads << Thread.new do
        100.times do |i|
          LingoFuse::CallbackErrorReporter.handler = ->(_s, _e) { i }
        end
      end
    end
    threads.each(&:join)

    assert true
  end
end