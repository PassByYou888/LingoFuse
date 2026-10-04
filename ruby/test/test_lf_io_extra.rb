# frozen_string_literal: true
#
# test_lf_io_extra.rb — Additional boundary tests for LingoFuse::LfIo.
#
# These complement test_lf_io.rb. The focus here is on:
#
#   - the NUL_BYTE and ENCODING constants
#   - edge cases of dumps_json / loads_json
#   - cstr normalisation
#   - peek_string_bytes cursor invariants
#   - read_all_bytes at various cursor positions
#   - try_read_json across all three outcomes
#
# The JSON-policy group needs no native library. The handle-based
# group is skipped when the native library is not available.
#
# ============================================================================
# NOTE ON FROZEN STRING LITERALS
# ============================================================================
# This file is frozen_string_literal: true. A string literal cannot be
# mutated in place; .force_encoding on a literal raises FrozenError.
# Any test that needs a mutable string uses .dup or an explicit
# String.new constructor.
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

# ============================================================================
# Group 1 — Constants and JSON policy (no native library required)
# ============================================================================

class TestLfIoExtraPure < Minitest::Test
  def setup
    skip 'LingoFuse::LfIo not loaded' unless defined?(LingoFuse::LfIo)
  end

  # ------------------------------------------------------------------
  # Constants
  # ------------------------------------------------------------------

  def test_nul_byte_constant
    assert_equal 0x00, LingoFuse::LfIo::NUL_BYTE
  end

  def test_encoding_constant
    assert_equal 'UTF-8', LingoFuse::LfIo::ENCODING
  end

  # ------------------------------------------------------------------
  # dumps_json — scalar edge cases
  # ------------------------------------------------------------------

  def test_dumps_json_nil
    assert_equal 'null', LingoFuse::LfIo.dumps_json(nil)
  end

  def test_dumps_json_true
    assert_equal 'true', LingoFuse::LfIo.dumps_json(true)
  end

  def test_dumps_json_false
    assert_equal 'false', LingoFuse::LfIo.dumps_json(false)
  end

  def test_dumps_json_integer
    assert_equal '42', LingoFuse::LfIo.dumps_json(42)
    assert_equal '-7', LingoFuse::LfIo.dumps_json(-7)
  end

  def test_dumps_json_float
    assert_equal '3.5', LingoFuse::LfIo.dumps_json(3.5)
  end

  def test_dumps_json_string
    assert_equal '"hello"', LingoFuse::LfIo.dumps_json('hello')
  end

  def test_dumps_json_empty_string
    assert_equal '""', LingoFuse::LfIo.dumps_json('')
  end

  def test_dumps_json_symbol_is_converted_to_string
    # JSON.generate converts Symbols to their string form.
    assert_equal '"sym"', LingoFuse::LfIo.dumps_json(:sym)
  end

  # ------------------------------------------------------------------
  # dumps_json — nested structures
  # ------------------------------------------------------------------

  def test_dumps_json_nested_object
    s = LingoFuse::LfIo.dumps_json({ 'a' => { 'b' => { 'c' => 1 } } })
    assert_equal '{"a":{"b":{"c":1}}}', s
  end

  def test_dumps_json_nested_array
    s = LingoFuse::LfIo.dumps_json([[1, 2], [3, 4]])
    assert_equal '[[1,2],[3,4]]', s
  end

  def test_dumps_json_mixed
    s = LingoFuse::LfIo.dumps_json({
      'int'   => 1,
      'float' => 1.5,
      'str'   => 'x',
      'bool'  => true,
      'null'  => nil,
      'arr'   => [1, 2]
    })
    # JSON.generate preserves insertion order for Hash in Ruby.
    assert_equal '{"int":1,"float":1.5,"str":"x","bool":true,"null":null,"arr":[1,2]}', s
  end

  # ------------------------------------------------------------------
  # loads_json
  # ------------------------------------------------------------------

  def test_loads_json_accepts_trailing_whitespace
    assert_equal({ 'a' => 1 }, LingoFuse::LfIo.loads_json('{"a":1}   '))
  end

  def test_loads_json_accepts_leading_whitespace
    assert_equal({ 'a' => 1 }, LingoFuse::LfIo.loads_json('   {"a":1}'))
  end

  def test_loads_json_rejects_bom_prefixed_input
    # JSON.parse rejects a BOM. We build a mutable string so that
    # force_encoding is legal under frozen_string_literal: true.
    text = String.new("\xEF\xBB\xBF{}", encoding: 'ASCII-8BIT')
    text = text.force_encoding('UTF-8')
    assert_raises(JSON::ParserError) do
      LingoFuse::LfIo.loads_json(text)
    end
  end

  def test_loads_json_integer_preserves_precision
    text = '{"n":9007199254740993}'
    result = LingoFuse::LfIo.loads_json(text)
    assert_equal 9_007_199_254_740_993, result['n']
  end

  # ------------------------------------------------------------------
  # cstr
  # ------------------------------------------------------------------

  def test_cstr_nil_becomes_empty_string
    assert_equal '', LingoFuse::LfIo.cstr(nil)
  end

  def test_cstr_symbol_becomes_string
    assert_equal 'sym', LingoFuse::LfIo.cstr(:sym)
  end

  def test_cstr_integer_becomes_string
    assert_equal '42', LingoFuse::LfIo.cstr(42)
  end

  def test_cstr_string_passes_through
    assert_equal 'hello', LingoFuse::LfIo.cstr('hello')
  end

  def test_cstr_unicode_passes_through
    assert_equal '你好', LingoFuse::LfIo.cstr('你好')
  end
end

# ============================================================================
# Group 2 — Handle-based I/O (native library required)
# ============================================================================

class TestLfIoExtraHandle < Minitest::Test
  def setup
    unless defined?(LingoFuse::DataHandle) &&
           defined?(LingoFuse::LfIo) &&
           LingoFuse.loaded?
      skip 'native library not loaded; handle-based tests are skipped'
    end
  end

  def with_handle(api_name)
    h = LingoFuse::DataHandle.new(api_name)
    begin
      yield h
    ensure
      h.dispose
    end
  end

  # ------------------------------------------------------------------
  # peek_string_bytes cursor invariants
  # ------------------------------------------------------------------

  def test_peek_preserves_cursor_across_multiple_calls
    with_handle('peek') do |h|
      LingoFuse::LfIo.write_string(h, 'payload')
      h.position = 2

      before = h.position
      LingoFuse::LfIo.peek_string_bytes(h)
      LingoFuse::LfIo.peek_string_bytes(h)
      LingoFuse::LfIo.peek_string_bytes(h)

      assert_equal before, h.position
    end
  end

  def test_peek_then_read_returns_same_bytes
    with_handle('peek_then_read') do |h|
      LingoFuse::LfIo.write_string(h, 'round-trip')
      h.position = 0

      peeked = LingoFuse::LfIo.peek_string_bytes(h)
      read   = LingoFuse::LfIo.read_string_bytes(h)

      assert_equal peeked, read
    end
  end

  # ------------------------------------------------------------------
  # read_all_bytes at various cursors
  # ------------------------------------------------------------------

  def test_read_all_bytes_at_cursor_zero
    with_handle('all_0') do |h|
      h.write_bytes('abcdef')
      h.position = 0
      assert_equal 'abcdef'.b, LingoFuse::LfIo.read_all_bytes(h)
    end
  end

  def test_read_all_bytes_at_end_returns_empty
    with_handle('all_end') do |h|
      h.write_bytes('abc')
      h.position = h.size
      assert_equal ''.b, LingoFuse::LfIo.read_all_bytes(h)
    end
  end

  def test_read_all_bytes_on_empty_buffer
    with_handle('all_empty') do |h|
      assert_equal ''.b, LingoFuse::LfIo.read_all_bytes(h)
    end
  end

  # ------------------------------------------------------------------
  # try_read_json three-way outcome
  # ------------------------------------------------------------------

  def test_try_read_json_empty_returns_nil
    with_handle('try_empty') do |h|
      LingoFuse::LfIo.write_string(h, '')
      h.position = 0
      assert_nil LingoFuse::LfIo.try_read_json(h)
    end
  end

  def test_try_read_json_valid_returns_value
    with_handle('try_valid') do |h|
      LingoFuse::LfIo.write_json(h, { 'k' => 'v' })
      h.position = 0
      assert_equal({ 'k' => 'v' }, LingoFuse::LfIo.try_read_json(h))
    end
  end

  def test_try_read_json_invalid_returns_nil_and_advances
    with_handle('try_invalid') do |h|
      LingoFuse::LfIo.write_string(h, 'not json')
      h.position = 0
      assert_nil LingoFuse::LfIo.try_read_json(h)
      # The cursor was advanced past the payload regardless.
      assert_operator h.position, :>, 0
    end
  end

  # ------------------------------------------------------------------
  # write_json always appends a NUL
  # ------------------------------------------------------------------

  def test_write_json_appends_exactly_one_nul
    with_handle('wj_nul') do |h|
      LingoFuse::LfIo.write_json(h, { 'a' => 1 })

      # The write left the cursor at the end. Rewind before reading.
      h.position = 0
      raw = LingoFuse::LfIo.read_all_bytes(h)

      refute_empty raw, 'write_json must have produced bytes'
      assert_equal 0, raw[-1].ord, 'last byte must be NUL'
      # The byte before the NUL is the closing brace.
      assert_equal '}'.ord, raw[-2].ord
    end
  end

  # ------------------------------------------------------------------
  # write_string with non-ASCII
  # ------------------------------------------------------------------

  def test_write_string_utf8_byte_count
    with_handle('utf8_len') do |h|
      # '你好' is 6 UTF-8 bytes + 1 NUL = 7.
      LingoFuse::LfIo.write_string(h, '你好')
      assert_equal 7, h.size
    end
  end

  # ------------------------------------------------------------------
  # write_string_bytes with embedded NUL — round-trip via raw
  # ------------------------------------------------------------------

  def test_write_string_bytes_preserves_embedded_nul_in_buffer
    with_handle('embedded_nul') do |h|
      LingoFuse::LfIo.write_string_bytes(h, "a\x00b".b)
      # 3 payload bytes + 1 framing NUL = 4.
      assert_equal 4, h.size

      h.position = 0
      raw = LingoFuse::LfIo.read_all_bytes(h)
      assert_equal "a\x00b\x00".b, raw
    end
  end
end