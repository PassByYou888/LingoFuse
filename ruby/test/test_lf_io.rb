# frozen_string_literal: true
#
# test_lf_io.rb — Unit tests for the LingoFuse::LfIo unified I/O module.
#
# ============================================================================
# TEST ORGANISATION
# ============================================================================
# The tests are split into two groups:
#
#   1. JSON-policy tests — pure-Ruby, no native library required. These
#      verify the serialization policy (`dumps_json` / `loads_json`).
#
#   2. Handle-based tests — require a live DataHandle. If the native
#      library is not available, each test is skipped with a clear
#      message instead of failing.
#
# Run this file directly:
#
#     ruby test/test_lf_io.rb
#
# Or via rake:
#
#     rake test
#
# ============================================================================

require 'minitest/autorun'

# Attempt to load the module. If the native library is missing, only the
# handle-based tests are skipped; the JSON-policy tests still run.
begin
  require_relative '../lib/lingofuse/lf_io'
rescue StandardError => e
  warn "Failed to load LingoFuse::LfIo: #{e.class}: #{e.message}"
end

# ============================================================================
# Group 1 — JSON policy (no native library required)
# ============================================================================

class TestLfIoJson < Minitest::Test
  def setup
    skip 'LingoFuse::LfIo not loaded' unless defined?(LingoFuse::LfIo)
  end

  # ------------------------------------------------------------------
  # Compactness
  # ------------------------------------------------------------------

  def test_dumps_json_is_compact
    s = LingoFuse::LfIo.dumps_json({ 'a' => 1, 'b' => 2 })
    assert_equal '{"a":1,"b":2}', s
    refute_includes s, "\n"
    refute_includes s, ' '
  end

  def test_dumps_json_handles_empty_object
    assert_equal '{}', LingoFuse::LfIo.dumps_json({})
  end

  def test_dumps_json_handles_empty_array
    assert_equal '[]', LingoFuse::LfIo.dumps_json([])
  end

  def test_dumps_json_handles_scalars
    assert_equal '42',     LingoFuse::LfIo.dumps_json(42)
    assert_equal 'null',   LingoFuse::LfIo.dumps_json(nil)
    assert_equal 'true',   LingoFuse::LfIo.dumps_json(true)
    assert_equal '"hi"',   LingoFuse::LfIo.dumps_json('hi')
  end

  # ------------------------------------------------------------------
  # Non-ASCII literalism
  # ------------------------------------------------------------------

  def test_dumps_json_preserves_cjk_literally
    s = LingoFuse::LfIo.dumps_json({ 'msg' => '你好世界' })
    assert_includes s, '你好世界'
    refute_includes s, '\\u'
  end

  def test_dumps_json_preserves_emoji_literally
    s = LingoFuse::LfIo.dumps_json({ 'msg' => '🌍' })
    assert_includes s, '🌍'
    refute_includes s, '\\u'
  end

  def test_dumps_json_preserves_accented_latin_literally
    s = LingoFuse::LfIo.dumps_json({ 'name' => 'café' })
    assert_includes s, 'café'
    refute_includes s, '\\u'
  end

  # ------------------------------------------------------------------
  # Round trip
  # ------------------------------------------------------------------

  def test_json_roundtrip_ascii
    original = { 'name' => 'Alice', 'age' => 30 }
    text = LingoFuse::LfIo.dumps_json(original)
    back = LingoFuse::LfIo.loads_json(text)
    assert_equal original, back
  end

  def test_json_roundtrip_unicode
    original = {
      'name' => '张三',
      'msg'  => '你好 🌍',
      'nested' => { 'café' => true }
    }
    text = LingoFuse::LfIo.dumps_json(original)
    back = LingoFuse::LfIo.loads_json(text)
    assert_equal original, back
  end

  def test_json_roundtrip_array
    original = [1, 'two', 3.5, true, nil, { 'four' => 4 }]
    text = LingoFuse::LfIo.dumps_json(original)
    back = LingoFuse::LfIo.loads_json(text)
    assert_equal original, back
  end

  # ------------------------------------------------------------------
  # loads_json is strict
  # ------------------------------------------------------------------

  def test_loads_json_is_strict_on_empty
    assert_raises(JSON::ParserError) { LingoFuse::LfIo.loads_json('') }
  end

  def test_loads_json_is_strict_on_garbage
    assert_raises(JSON::ParserError) { LingoFuse::LfIo.loads_json('not json') }
  end

  def test_loads_json_rejects_trailing_comma
    assert_raises(JSON::ParserError) { LingoFuse::LfIo.loads_json('{"a":1,}') }
  end

  def test_loads_json_rejects_single_quotes
    assert_raises(JSON::ParserError) { LingoFuse::LfIo.loads_json("{'a':1}") }
  end

  # ------------------------------------------------------------------
  # dumps_json wraps serialization failures as LingoFuse::IoError
  # ------------------------------------------------------------------

  def test_dumps_json_wraps_generator_error
    # An object whose `to_json` raises is translated to IoError.
    # We use a purpose-built class for the test.
    bad = Object.new
    def bad.to_json(*)
      raise JSON::GeneratorError, 'intentional failure'
    end

    assert_raises(LingoFuse::IoError) do
      LingoFuse::LfIo.dumps_json(bad)
    end
  end

  # ------------------------------------------------------------------
  # cstr normalisation
  # ------------------------------------------------------------------

  def test_cstr_normalises_nil_to_empty_string
    assert_equal '', LingoFuse::LfIo.cstr(nil)
  end

  def test_cstr_converts_non_strings
    assert_equal '42', LingoFuse::LfIo.cstr(42)
  end

  def test_cstr_passes_strings_through
    assert_equal 'hello', LingoFuse::LfIo.cstr('hello')
  end
end

# ============================================================================
# Group 2 — Handle-based I/O (native library required)
# ============================================================================

class TestLfIoHandleIo < Minitest::Test
  def setup
    unless defined?(LingoFuse::DataHandle) &&
           defined?(LingoFuse::LfIo)
      skip 'native library not loaded; handle-based tests are skipped'
    end
  end

  # Runs a block with an auto-disposed DataHandle.
  def with_handle(api_name)
    h = LingoFuse::DataHandle.new(api_name)
    begin
      yield h
    ensure
      h.dispose
    end
  end

  # ------------------------------------------------------------------
  # String round trip
  # ------------------------------------------------------------------

  def test_write_read_string_roundtrip
    with_handle('t_str') do |h|
      LingoFuse::LfIo.write_string(h, 'hello, 世界 🌍')
      h.position = 0
      assert_equal 'hello, 世界 🌍', LingoFuse::LfIo.read_string(h)
    end
  end

  def test_empty_string_writes_single_nul
    with_handle('t_empty') do |h|
      LingoFuse::LfIo.write_string(h, '')
      assert_equal 1, h.size
      h.position = 0
      assert_equal '', LingoFuse::LfIo.read_string(h)
      assert_equal 1, h.position
    end
  end

  def test_nil_is_treated_as_empty_string
    with_handle('t_nil') do |h|
      LingoFuse::LfIo.write_string(h, nil)
      assert_equal 1, h.size
      h.position = 0
      assert_equal '', LingoFuse::LfIo.read_string(h)
    end
  end

  # ------------------------------------------------------------------
  # Byte-oriented I/O
  # ------------------------------------------------------------------

  def test_write_string_bytes_appends_nul
    with_handle('t_bytes') do |h|
      LingoFuse::LfIo.write_string_bytes(h, "\x01\x02\x03".b)
      # 3 payload bytes + 1 framing NUL = 4.
      assert_equal 4, h.size
      h.position = 0
      assert_equal "\x01\x02\x03".b, LingoFuse::LfIo.read_string_bytes(h)
    end
  end

  def test_read_string_bytes_stops_at_first_nul
    with_handle('t_stop') do |h|
      # Payload with an embedded NUL: 'a', NUL, 'b', framing NUL.
      LingoFuse::LfIo.write_string_bytes(h, "a\x00b".b)
      h.position = 0
      # The reader stops at the first NUL; only "a" is returned.
      assert_equal 'a'.b, LingoFuse::LfIo.read_string_bytes(h)
    end
  end

  def test_read_all_bytes_is_raw
    with_handle('t_all') do |h|
      h.write_bytes("\x00\x01\x02\xFF".b)
      h.position = 0
      assert_equal "\x00\x01\x02\xFF".b, LingoFuse::LfIo.read_all_bytes(h)
    end
  end

  # ------------------------------------------------------------------
  # peek
  # ------------------------------------------------------------------

  def test_peek_does_not_advance
    with_handle('t_peek') do |h|
      LingoFuse::LfIo.write_string(h, 'peek-me')
      h.position = 0

      first  = LingoFuse::LfIo.peek_string_bytes(h)
      second = LingoFuse::LfIo.peek_string_bytes(h)

      assert_equal 'peek-me'.b, first
      assert_equal first, second
      assert_equal 0, h.position

      # A real read now consumes the payload.
      assert_equal 'peek-me'.b, LingoFuse::LfIo.read_string_bytes(h)
    end
  end

  # ------------------------------------------------------------------
  # JSON I/O through a handle
  # ------------------------------------------------------------------

  def test_write_read_json_roundtrip
    with_handle('t_json') do |h|
      original = { 'name' => '张三', 'age' => 30, 'emoji' => '🌍' }
      LingoFuse::LfIo.write_json(h, original)
      h.position = 0
      assert_equal original, LingoFuse::LfIo.read_json(h)
    end
  end

  def test_write_json_produces_literal_utf8_on_the_wire
    with_handle('t_json_wire') do |h|
      LingoFuse::LfIo.write_json(h, { 'msg' => '你好' })
      h.position = 0
      raw = LingoFuse::LfIo.read_string_bytes(h)
      text = raw.dup.force_encoding('UTF-8')

      assert_includes text, '你好'
      refute_includes text, '\\u'
    end
  end

  def test_read_json_returns_nil_on_empty
    with_handle('t_json_empty') do |h|
      LingoFuse::LfIo.write_string(h, '')
      h.position = 0
      assert_nil LingoFuse::LfIo.read_json(h)
    end
  end

  def test_read_json_raises_on_invalid
    with_handle('t_json_bad') do |h|
      LingoFuse::LfIo.write_string(h, 'not json')
      h.position = 0
      assert_raises(JSON::ParserError) do
        LingoFuse::LfIo.read_json(h)
      end
    end
  end

  def test_try_read_json_returns_nil_on_invalid
    with_handle('t_json_try') do |h|
      LingoFuse::LfIo.write_string(h, 'not json')
      h.position = 0
      assert_nil LingoFuse::LfIo.try_read_json(h)
    end
  end

  def test_try_read_json_returns_value_on_valid
    with_handle('t_json_try_ok') do |h|
      LingoFuse::LfIo.write_json(h, { 'a' => 1 })
      h.position = 0
      assert_equal({ 'a' => 1 }, LingoFuse::LfIo.try_read_json(h))
    end
  end

  # ------------------------------------------------------------------
  # Fault tolerance: raw payload without NUL
  # ------------------------------------------------------------------

  def test_read_without_nul_consumes_remaining
    with_handle('t_no_nul') do |h|
      # Raw JSON, no trailing NUL.
      h.write_bytes('{"a":1}'.b)
      h.position = 0
      assert_equal '{"a":1}', LingoFuse::LfIo.read_string(h)
    end
  end
end