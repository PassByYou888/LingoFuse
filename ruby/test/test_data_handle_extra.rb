# frozen_string_literal: true
#
# test_data_handle_extra.rb — Additional boundary tests for DataHandle.
#
# These complement test_data_handle.rb; the two files together cover
# every public method of LingoFuse::DataHandle. All tests require the
# native library.
#

require 'minitest/autorun'

# ---------------------------------------------------------------------------
# Load path setup
# ---------------------------------------------------------------------------
# lib/ must be on $LOAD_PATH before requiring the binding. The C
# extension is `require`d by native_bridge.rb through a bare name
# (`require 'lingofuse_ext'`), which only consults $LOAD_PATH. If lib/
# is not on the load path, the extension will silently fail to load
# and remote callbacks will not be receivable, even though the rest of
# the binding works.
#
# The other test files use the same pattern. Using $LOAD_PATH +
# `require 'lingofuse'` (rather than `require_relative`) keeps this
# file consistent with the rest of the suite.
# ---------------------------------------------------------------------------

_lib_dir = File.expand_path('../lib', __dir__)
$LOAD_PATH.unshift(_lib_dir) unless $LOAD_PATH.include?(_lib_dir)

begin
  require 'lingofuse'
rescue StandardError, LoadError => e
  warn "Failed to load LingoFuse: #{e.class}: #{e.message}"
end

class TestDataHandleExtra < Minitest::Test
  def setup
    unless defined?(LingoFuse::DataHandle) && LingoFuse.loaded?
      skip 'native library not loaded'
    end
  end

  def unique_name(prefix)
    "#{prefix}_#{Process.pid}_#{rand(1_000_000)}"
  end

  def open_handle(prefix = 'extra')
    name = unique_name(prefix)
    h = LingoFuse::DataHandle.new(name)
    return h unless block_given?
    begin
      yield h
    ensure
      h.dispose
    end
  end

  # ==================================================================
  # Scalar write return values
  # ==================================================================

  def test_scalar_writes_return_true_on_success
    open_handle do |h|
      assert_equal true, h.write_int8(1)
      assert_equal true, h.write_uint8(1)
      assert_equal true, h.write_int16(1)
      assert_equal true, h.write_uint16(1)
      assert_equal true, h.write_int32(1)
      assert_equal true, h.write_uint32(1)
      assert_equal true, h.write_int64(1)
      assert_equal true, h.write_uint64(1)
      assert_equal true, h.write_single(1.0)
      assert_equal true, h.write_double(1.0)
    end
  end

  def test_scalar_writes_advance_position_correctly
    open_handle do |h|
      h.write_int8(0);     assert_equal 1,  h.position
      h.write_int16(0);    assert_equal 3,  h.position
      h.write_int32(0);    assert_equal 7,  h.position
      h.write_int64(0);    assert_equal 15, h.position
      h.write_single(0.0); assert_equal 19, h.position
      h.write_double(0.0); assert_equal 27, h.position
    end
  end

  # ==================================================================
  # read_string_bytes on various payloads
  # ==================================================================

  def test_read_string_bytes_on_empty_buffer
    open_handle do |h|
      assert_equal ''.b, h.read_string_bytes
    end
  end

  def test_read_string_bytes_after_writing_empty_string
    open_handle do |h|
      h.write_string('')
      h.position = 0
      assert_equal ''.b, h.read_string_bytes
    end
  end

  def test_read_string_bytes_when_no_nul_present
    open_handle do |h|
      h.write_bytes('abc'.b)
      h.position = 0
      assert_equal 'abc'.b, h.read_string_bytes
    end
  end

  # ==================================================================
  # read_all_bytes
  # ==================================================================

  def test_read_all_bytes_on_empty_handle
    open_handle do |h|
      assert_equal ''.b, h.read_all_bytes
    end
  end

  def test_read_all_bytes_from_middle
    open_handle do |h|
      h.write_bytes('abcdef'.b)
      h.position = 3
      assert_equal 'def'.b, h.read_all_bytes
      assert_equal h.size, h.position
    end
  end

  # ==================================================================
  # get_buffer_pointer
  # ==================================================================

  def test_get_buffer_pointer_on_empty_handle
    open_handle do |h|
      # An empty buffer may legitimately return nil or a zero pointer.
      ptr = h.get_buffer_pointer
      assert(ptr.nil? || (ptr.respond_to?(:to_i) && ptr.to_i.zero?))
    end
  end

  def test_get_buffer_pointer_after_write
    open_handle do |h|
      h.write_bytes('abc')
      ptr = h.get_buffer_pointer
      refute_nil ptr
      refute ptr.respond_to?(:to_i) && ptr.to_i.zero?
    end
  end

  # ==================================================================
  # try_read_string
  # ==================================================================

  def test_try_read_string_at_end_returns_nil
    open_handle do |h|
      h.write_string('x')
      h.position = h.size
      assert_nil h.try_read_string
    end
  end

  def test_try_read_string_returns_empty_when_nul_is_next
    open_handle do |h|
      h.write_string('')
      h.position = 0
      assert_equal '', h.try_read_string
    end
  end

  # ==================================================================
  # String terminator edge cases
  # ==================================================================

  def test_write_string_utf8_multibyte_appends_one_nul
    open_handle do |h|
      h.write_string('你好')
      # 6 UTF-8 bytes + 1 NUL = 7
      assert_equal 7, h.size
      buf = h.get_buffer_pointer
      ptr = Fiddle::Pointer.new(buf)
      assert_equal 0, ptr[6]
    end
  end

  def test_read_string_with_invalid_utf8_uses_replacement_character
    open_handle do |h|
      # 0xFF is never a valid UTF-8 lead byte.
      h.write_bytes("\xFF\xFF".b)
      h.write_bytes("\x00".b)
      h.position = 0
      text = h.read_string
      # String#scrub replaces invalid bytes with U+FFFD.
      assert_includes text, "\uFFFD"
    end
  end

  # ==================================================================
  # try_read_bytes exact-zero count
  # ==================================================================

  def test_try_read_bytes_zero_returns_empty
    open_handle do |h|
      assert_equal ''.b, h.try_read_bytes(0)
    end
  end

  def test_read_bytes_exact_zero_returns_empty
    open_handle do |h|
      assert_equal ''.b, h.read_bytes_exact(0)
    end
  end

  # ==================================================================
  # Large payload
  # ==================================================================

  def test_large_payload_roundtrip
    open_handle do |h|
      payload = (0...128 * 1024).map { |i| (i & 0xFF).chr }.join.b
      h.write_bytes(payload)
      assert_equal payload.bytesize, h.size
      h.position = 0
      assert_equal payload, h.read_bytes(payload.bytesize)
    end
  end

  # ==================================================================
  # Block-form disposal on various exits
  # ==================================================================

  def test_open_disposes_on_normal_exit
    name = unique_name('open_ok')
    captured = nil
    LingoFuse::DataHandle.open(name) { |h| captured = h }
    refute captured.valid?
  end

  def test_open_disposes_on_raise
    name = unique_name('open_raise')
    captured = nil
    begin
      LingoFuse::DataHandle.open(name) do |h|
        captured = h
        raise 'intentional'
      end
    rescue RuntimeError
      # expected
    end
    refute captured.valid?
  end

  # ==================================================================
  # create_permanent does not auto-recycle
  # ==================================================================

  def test_permanent_handle_still_usable_after_a_pause
    h = LingoFuse::DataHandle.create_permanent(unique_name('perm'))
    begin
      h.write_int32(7)
      # A one-second pause is too short to trigger the 10-minute idle
      # reclaimer, so this test verifies only that no incidental
      # scan releases the handle.
      sleep 1
      h.position = 0
      assert_equal 7, h.read_int32
    ensure
      h.dispose
    end
  end

  def test_permanent_dispose_is_synchronous
    h = LingoFuse::DataHandle.create_permanent(unique_name('perm_sync'))
    h.write_int32(1)
    h.dispose
    refute h.valid?
    assert_nil h.raw
  end
end