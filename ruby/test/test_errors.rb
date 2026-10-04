# frozen_string_literal: true
#
# test_errors.rb — Unit tests for the LingoFuse exception hierarchy.
#
# This file does NOT require the native library. It can therefore run
# on any machine, whether or not the LingoFuse runtime is installed.
#

require 'minitest/autorun'

require_relative '../lib/lingofuse/errors'

class TestErrors < Minitest::Test
  # ------------------------------------------------------------------
  # Base class
  # ------------------------------------------------------------------

  def test_base_error_is_a_standard_error
    assert LingoFuse::Error.ancestors.include?(StandardError)
  end

  def test_base_error_message
    e = LingoFuse::Error.new('something went wrong')
    assert_equal 'something went wrong', e.message
  end

  # ------------------------------------------------------------------
  # LibraryLoadError
  # ------------------------------------------------------------------

  def test_library_load_error_is_a_lingofuse_error
    assert LingoFuse::LibraryLoadError.ancestors.include?(LingoFuse::Error)
  end

  def test_library_load_error_message
    e = LingoFuse::LibraryLoadError.new('cannot load')
    assert_equal 'cannot load', e.message
  end

  # ------------------------------------------------------------------
  # CallError
  # ------------------------------------------------------------------

  def test_call_error_is_a_lingofuse_error
    assert LingoFuse::CallError.ancestors.include?(LingoFuse::Error)
  end

  def test_call_error_holds_target_app
    e = LingoFuse::CallError.new('failed', target_app: 'Calc')
    assert_equal 'Calc', e.target_app
    assert_nil e.target_api
  end

  def test_call_error_holds_target_api
    e = LingoFuse::CallError.new('failed', target_app: 'Calc', target_api: 'add')
    assert_equal 'Calc', e.target_app
    assert_equal 'add', e.target_api
  end

  def test_call_error_defaults_to_nil_target
    e = LingoFuse::CallError.new('failed')
    assert_nil e.target_app
    assert_nil e.target_api
  end

  # ------------------------------------------------------------------
  # IoError
  # ------------------------------------------------------------------

  def test_io_error_is_a_lingofuse_error
    assert LingoFuse::IoError.ancestors.include?(LingoFuse::Error)
  end

  def test_io_error_holds_operation
    e = LingoFuse::IoError.new('short read', operation: 'read_bytes')
    assert_equal 'read_bytes', e.operation
  end

  def test_io_error_operation_defaults_to_nil
    e = LingoFuse::IoError.new('failure')
    assert_nil e.operation
  end

  # ------------------------------------------------------------------
  # ObjectDisposedError
  # ------------------------------------------------------------------

  def test_object_disposed_error_is_a_lingofuse_error
    assert LingoFuse::ObjectDisposedError.ancestors.include?(LingoFuse::Error)
  end

  def test_object_disposed_error_holds_object_name
    e = LingoFuse::ObjectDisposedError.new('DataHandle')
    assert_equal 'DataHandle', e.object_name
  end

  def test_object_disposed_error_message_mentions_object
    e = LingoFuse::ObjectDisposedError.new('DataHandle')
    assert_includes e.message, 'DataHandle'
    assert_includes e.message.downcase, 'disposed'
  end

  # ------------------------------------------------------------------
  # RegistrationError
  # ------------------------------------------------------------------

  def test_registration_error_is_a_lingofuse_error
    assert LingoFuse::RegistrationError.ancestors.include?(LingoFuse::Error)
  end

  def test_registration_error_holds_api_name
    e = LingoFuse::RegistrationError.new('duplicate', api_name: 'add')
    assert_equal 'add', e.api_name
  end

  def test_registration_error_api_name_defaults_to_nil
    e = LingoFuse::RegistrationError.new('failure')
    assert_nil e.api_name
  end

  # ------------------------------------------------------------------
  # CallbackError
  # ------------------------------------------------------------------

  def test_callback_error_is_a_lingofuse_error
    assert LingoFuse::CallbackError.ancestors.include?(LingoFuse::Error)
  end

  def test_callback_error_holds_source
    cause = ArgumentError.new('oops')
    e = LingoFuse::CallbackError.new('AppHandle.register_call[add]', cause)
    assert_equal 'AppHandle.register_call[add]', e.source
  end

  def test_callback_error_holds_original_cause
    cause = ArgumentError.new('oops')
    e = LingoFuse::CallbackError.new('source', cause)
    assert_same cause, e.original_cause
  end

  def test_callback_error_message_includes_exception_message
    cause = ArgumentError.new('oops')
    e = LingoFuse::CallbackError.new('source', cause)
    assert_includes e.message, 'oops'
    assert_includes e.message, 'source'
  end

  def test_callback_error_accepts_non_exception_cause
    # The callback body may throw any value; the reporter must still
    # produce a useful message.
    e = LingoFuse::CallbackError.new('source', 'plain string')
    assert_includes e.message, 'plain string'
    assert_equal 'plain string', e.original_cause
  end

  # ------------------------------------------------------------------
  # rescue hierarchy
  # ------------------------------------------------------------------

  def test_rescuing_base_class_catches_every_subclass
    [
      LingoFuse::LibraryLoadError.new('x'),
      LingoFuse::CallError.new('x'),
      LingoFuse::IoError.new('x'),
      LingoFuse::ObjectDisposedError.new('x'),
      LingoFuse::RegistrationError.new('x'),
      LingoFuse::CallbackError.new('x', 'y')
    ].each do |e|
      caught = false
      begin
        raise e
      rescue LingoFuse::Error
        caught = true
      end
      assert caught, "#{e.class} was not caught by LingoFuse::Error"
    end
  end
end