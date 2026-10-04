# frozen_string_literal: true
#
# test_data_handle.rb — Unit tests for the LingoFuse::DataHandle wrapper.
#
# Every test in this file requires the native LingoFuse library. If the
# library is not available, the tests are skipped with a clear message
# rather than failing.
#
# Run this file directly:
#
#     ruby test/test_data_handle.rb
#
# ============================================================================
# COVERAGE
# ============================================================================
#   - Construction (auto-recycled and permanent)
#   - Position and size operations
#   - Byte I/O (partial and exact read families)
#   - Scalar I/O (all ten little-endian scalar types)
#   - NUL-framed string I/O
#   - Ownership semantics (owning vs borrowing)
#   - Lifetime (dispose, disposal idempotence, use-after-dispose)
#   - Block form (`DataHandle.open`)
#
# ============================================================================

require 'minitest/autorun'
require 'fiddle'

_lib_dir = File.expand_path('../lib', __dir__)
$LOAD_PATH.unshift(_lib_dir) unless $LOAD_PATH.include?(_lib_dir)

begin
  require 'lingofuse'
rescue StandardError, LoadError => e
  warn "Failed to load LingoFuse: #{e.class}: #{e.message}"
end

class TestDataHandle < Minitest::Test
  def setup
    skip 'LingoFuse::DataHandle not loaded' unless defined?(LingoFuse::DataHandle)
  end

  # ------------------------------------------------------------------
  # Small helper: unique API name per test to avoid pool interference.
  # ------------------------------------------------------------------

  def unique_api_name(prefix)
    "#{prefix}_#{Process.pid}_#{rand(1_000_000)}"
  end

  def open_handle(prefix = 'tdh')
    name = unique_api_name(prefix)
    h = LingoFuse::DataHandle.new(name)
    return h unless block_given?
    begin
      yield h
    ensure
      h.dispose
    end
  end

  # ==================================================================
  # Construction
  # ==================================================================

  def test_new_creates_valid_handle
    open_handle do |h|
      assert h.valid?
      assert h.owning?
      refute_nil h.raw
      assert_equal 0, h.size
      assert_equal 0, h.position
    end
  end

  def test_create_permanent_creates_valid_handle
    name = unique_api_name('perm')
    h = LingoFuse::DataHandle.create_permanent(name)
    begin
      assert h.valid?
      assert h.owning?
      assert_equal 0, h.size
    ensure
      h.dispose
    end
  end

  def test_new_stores_api_name
    name = unique_api_name('named')
    h = LingoFuse::DataHandle.new(name)
    begin
      assert_equal name, h.api_name
    ensure
      h.dispose
    end
  end

  # ==================================================================
  # Position and size
  # ==================================================================

  def test_write_advances_size_and_position
    open_handle do |h|
      h.write_bytes('abcd')
      assert_equal 4, h.size
      assert_equal 4, h.position
    end
  end

  def test_set_position_rewinds
    open_handle do |h|
      h.write_bytes('abcd')
      h.position = 2
      assert_equal 2, h.position
    end
  end

  def test_set_position_beyond_size_is_accepted
    open_handle do |h|
      # LF_SetPos accepts a position past the current size without
      # error. The underlying buffer is allocated lazily, on the next
      # write, so `size` may still report 0 immediately after the call.
      # Only the logical cursor is required to reflect the new value.
      h.position = 8
      assert_equal 8, h.position
    end
  end

  def test_set_size_grows_and_shrinks
    open_handle do |h|
      h.write_bytes('abcdef')
      assert_equal 6, h.size
      h.size = 3
      assert_equal 3, h.size
      h.size = 10
      assert_equal 10, h.size
    end
  end

  def test_negative_position_raises
    open_handle do |h|
      assert_raises(ArgumentError) { h.position = -1 }
    end
  end

  def test_negative_size_raises
    open_handle do |h|
      assert_raises(ArgumentError) { h.size = -1 }
    end
  end

  # ==================================================================
  # Byte I/O — partial read family
  # ==================================================================

  def test_read_bytes_returns_all_when_enough_data
    open_handle do |h|
      h.write_bytes("\x01\x02\x03\x04".b)
      h.position = 0
      assert_equal "\x01\x02\x03\x04".b, h.read_bytes(4)
    end
  end

  def test_read_bytes_returns_fewer_when_insufficient
    open_handle do |h|
      h.write_bytes("\x01\x02".b)
      h.position = 0
      assert_equal "\x01\x02".b, h.read_bytes(10)
    end
  end

  def test_read_bytes_returns_empty_at_end
    open_handle do |h|
      h.write_bytes("\x01".b)
      h.position = 1
      assert_equal ''.b, h.read_bytes(4)
    end
  end

  def test_write_bytes_empty_is_noop
    open_handle do |h|
      assert_equal 0, h.write_bytes('')
      assert_equal 0, h.size
    end
  end

  def test_write_bytes_nil_is_noop
    open_handle do |h|
      assert_equal 0, h.write_bytes(nil)
      assert_equal 0, h.size
    end
  end

  # ==================================================================
  # Byte I/O — exact read family
  # ==================================================================

  def test_read_bytes_exact_success
    open_handle do |h|
      h.write_bytes("\x01\x02\x03\x04".b)
      h.position = 0
      assert_equal "\x01\x02\x03\x04".b, h.read_bytes_exact(4)
      assert_equal 4, h.position
    end
  end

  def test_read_bytes_exact_short_raises_and_restores_cursor
    open_handle do |h|
      h.write_bytes("\x01\x02".b)
      h.position = 0

      err = assert_raises(LingoFuse::IoError) { h.read_bytes_exact(4) }
      assert_equal 'read_bytes_exact', err.operation
      assert_equal 0, h.position, 'cursor must be restored on short read'
    end
  end

  def test_try_read_bytes_returns_nil_on_short
    open_handle do |h|
      h.write_bytes("\x01\x02".b)
      h.position = 0
      assert_nil h.try_read_bytes(4)
      assert_equal 0, h.position
    end
  end

  def test_try_read_bytes_returns_data_on_success
    open_handle do |h|
      h.write_bytes("\x01\x02".b)
      h.position = 0
      assert_equal "\x01\x02".b, h.try_read_bytes(2)
    end
  end

  def test_read_all_bytes_consumes_remaining
    open_handle do |h|
      h.write_bytes("\x01\x02\x03\x04\x05".b)
      h.position = 2
      assert_equal "\x03\x04\x05".b, h.read_all_bytes
      assert_equal h.size, h.position
    end
  end

  # ==================================================================
  # Scalar I/O
  # ==================================================================

  def test_scalar_int8_roundtrip
    open_handle do |h|
      h.write_int8(-128)
      h.write_int8(127)
      h.position = 0
      assert_equal(-128, h.read_int8)
      assert_equal 127, h.read_int8
    end
  end

  def test_scalar_uint8_roundtrip
    open_handle do |h|
      h.write_uint8(0)
      h.write_uint8(255)
      h.position = 0
      assert_equal 0,   h.read_uint8
      assert_equal 255, h.read_uint8
    end
  end

  def test_scalar_int16_roundtrip
    open_handle do |h|
      h.write_int16(-32_768)
      h.write_int16(32_767)
      h.position = 0
      assert_equal(-32_768, h.read_int16)
      assert_equal 32_767,  h.read_int16
    end
  end

  def test_scalar_uint16_roundtrip
    open_handle do |h|
      h.write_uint16(0)
      h.write_uint16(65_535)
      h.position = 0
      assert_equal 0,      h.read_uint16
      assert_equal 65_535, h.read_uint16
    end
  end

  def test_scalar_int32_roundtrip
    open_handle do |h|
      h.write_int32(-2_147_483_648)
      h.write_int32(2_147_483_647)
      h.position = 0
      assert_equal(-2_147_483_648, h.read_int32)
      assert_equal 2_147_483_647,  h.read_int32
    end
  end

  def test_scalar_uint32_roundtrip
    open_handle do |h|
      h.write_uint32(0)
      h.write_uint32(4_294_967_295)
      h.position = 0
      assert_equal 0,           h.read_uint32
      assert_equal 4_294_967_295, h.read_uint32
    end
  end

  def test_scalar_int64_roundtrip
    open_handle do |h|
      h.write_int64(-9_223_372_036_854_775_808)
      h.write_int64(9_223_372_036_854_775_807)
      h.position = 0
      assert_equal(-9_223_372_036_854_775_808, h.read_int64)
      assert_equal 9_223_372_036_854_775_807,  h.read_int64
    end
  end

  def test_scalar_uint64_roundtrip
    open_handle do |h|
      h.write_uint64(0)
      h.write_uint64(18_446_744_073_709_551_615)
      h.position = 0
      assert_equal 0,                            h.read_uint64
      assert_equal 18_446_744_073_709_551_615,   h.read_uint64
    end
  end

  def test_scalar_single_roundtrip
    open_handle do |h|
      h.write_single(3.14)
      h.position = 0
      assert_in_delta 3.14, h.read_single, 1e-5
    end
  end

  def test_scalar_double_roundtrip
    open_handle do |h|
      h.write_double(3.141592653589793)
      h.position = 0
      assert_in_delta 3.141592653589793, h.read_double, 1e-12
    end
  end

  def test_scalar_read_exact_on_short_raises
    open_handle do |h|
      h.write_bytes("\x01".b) # only 1 byte available
      h.position = 0
      assert_raises(LingoFuse::IoError) { h.read_int32 }
    end
  end

  # ==================================================================
  # String I/O
  # ==================================================================

  def test_string_roundtrip_ascii
    open_handle do |h|
      h.write_string('hello')
      h.position = 0
      assert_equal 'hello', h.read_string
    end
  end

  def test_string_roundtrip_utf8
    open_handle do |h|
      h.write_string('hello, 世界 🌍')
      h.position = 0
      assert_equal 'hello, 世界 🌍', h.read_string
    end
  end

  def test_empty_string_writes_single_nul
    open_handle do |h|
      h.write_string('')
      assert_equal 1, h.size
      h.position = 0
      assert_equal '', h.read_string
      assert_equal 1, h.position
    end
  end

  def test_string_terminator_is_single_byte
    open_handle do |h|
      h.write_string('abc')
      assert_equal 4, h.size
      ptr = Fiddle::Pointer.new(h.get_buffer_pointer)
      # Fiddle::Pointer#[] returns the byte at the given offset as a
      # 0..255 Integer. This replaces the FFI-era get_uint8() call.
      assert_equal 'a'.ord, ptr[0]
      assert_equal 'b'.ord, ptr[1]
      assert_equal 'c'.ord, ptr[2]
      assert_equal 0,       ptr[3]
    end
  end

  def test_read_string_fault_tolerant_without_nul
    open_handle do |h|
      h.write_bytes('{"a":1}'.b)
      h.position = 0
      assert_equal '{"a":1}', h.read_string
    end
  end

  def test_try_read_string_returns_nil_at_end
    open_handle do |h|
      h.write_string('x')
      h.position = 1
      # Cursor is at the NUL byte; there is no data left before the
      # terminator, so `read_string` returns "".
      assert_equal '', h.read_string

      # After the NUL is consumed, the cursor is past the end.
      assert_nil h.try_read_string
    end
  end

  # ==================================================================
  # Ownership semantics
  # ==================================================================

  def test_owning_handle_frees_on_dispose
    name = unique_api_name('owning')
    h = LingoFuse::DataHandle.new(name)
    assert h.owning?
    h.dispose
    refute h.valid?
    assert_nil h.raw
  end

  def test_borrowed_handle_dispose_is_noop
    # Use a real owning handle first, then produce a borrowed view of
    # the same native handle to test the borrow path.
    owner = LingoFuse::DataHandle.new(unique_api_name('owner'))
    begin
      borrowed = LingoFuse::DataHandle.borrow(owner.raw)
      refute borrowed.owning?

      # dispose on a borrowed handle must be a no-op.
      borrowed.dispose
      assert borrowed.valid?, 'borrowed handle must remain valid after dispose'
      refute_nil borrowed.raw
      assert_equal owner.raw, borrowed.raw
    ensure
      owner.dispose
    end
  end

  def test_from_raw_owned_true_frees_on_dispose
    owner = LingoFuse::DataHandle.new(unique_api_name('wrap'))
    raw = owner.raw
    # Detach the raw handle from the owner so the owner does not free it.
    owner.instance_variable_set(:@disposed, true)
    owner.instance_variable_set(:@handle, nil)

    wrapped = LingoFuse::DataHandle.from_raw(raw, true)
    assert wrapped.owning?
    wrapped.dispose
    refute wrapped.valid?
  end

  # ==================================================================
  # Lifetime and error handling
  # ==================================================================

  def test_dispose_is_idempotent
    h = LingoFuse::DataHandle.new(unique_api_name('idem'))
    h.dispose
    h.dispose
    h.dispose
    refute h.valid?
  end

  def test_use_after_dispose_raises
    h = LingoFuse::DataHandle.new(unique_api_name('uad'))
    h.dispose
    assert_raises(LingoFuse::ObjectDisposedError) { h.size }
    assert_raises(LingoFuse::ObjectDisposedError) { h.read_bytes(1) }
    assert_raises(LingoFuse::ObjectDisposedError) { h.write_bytes('x') }
  end

  def test_block_form_disposes_even_on_exception
    name = unique_api_name('block')
    captured = nil
    begin
      LingoFuse::DataHandle.open(name) do |h|
        captured = h
        raise 'intentional'
      end
    rescue RuntimeError
      # expected
    end
    refute_nil captured
    refute captured.valid?, 'block form must dispose the handle on exception'
  end

  def test_block_form_returns_block_value
    name = unique_api_name('ret')
    result = LingoFuse::DataHandle.open(name) do |h|
      h.write_int32(42)
      h.position = 0
      h.read_int32
    end
    assert_equal 42, result
  end

  # ==================================================================
  # Buffer pointer
  # ==================================================================

  def test_get_buffer_pointer_returns_non_null_after_write
    open_handle do |h|
      h.write_bytes('abc')
      ptr = h.get_buffer_pointer
      refute_nil ptr
      refute ptr.respond_to?(:to_i) && ptr.to_i.zero?
    end
  end
end