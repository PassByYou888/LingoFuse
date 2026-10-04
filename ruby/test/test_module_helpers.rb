# frozen_string_literal: true
#
# test_module_helpers.rb — Tests for the top-level LingoFuse module.
#
# Covers: VERSION, load_library, loaded?, library_name, platform,
# platform_library_name, cstr_ptr, read_cstr.
#
# The cstr_ptr / read_cstr helpers are exercised with real bytes and
# with a real Fiddle::Pointer round trip so that the NUL terminator
# contract is verified, not just the return type.
#
# ============================================================================
# NOTE ON FIDDLE::Pointer#[]
# ============================================================================
# Fiddle::Pointer#[] returns a SIGNED byte in the range -128..127, not
# an unsigned 0..255. Every byte comparison below therefore masks with
# 0xFF. Do not remove those masks: they are what makes the assertion
# work for bytes above 0x7F (which is exactly what UTF-8 needs).
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

class TestModuleHelpers < Minitest::Test
  def setup
    skip 'LingoFuse not loaded' unless defined?(LingoFuse)
  end

  # ------------------------------------------------------------------
  # VERSION
  # ------------------------------------------------------------------

  def test_version_is_a_non_empty_string
    assert_kind_of String, LingoFuse::VERSION
    refute_empty LingoFuse::VERSION
  end

  def test_version_looks_like_semver
    assert_match(/\A\d+\.\d+\.\d+\z/, LingoFuse::VERSION)
  end

  # ------------------------------------------------------------------
  # load_library / loaded?
  # ------------------------------------------------------------------

  def test_load_library_returns_true
    assert_equal true, LingoFuse.load_library
  end

  def test_load_library_is_idempotent
    assert_equal true, LingoFuse.load_library
    assert_equal true, LingoFuse.load_library
  end

  def test_loaded_predicate_returns_boolean
    value = LingoFuse.loaded?
    assert_includes [true, false], value
  end

  # ------------------------------------------------------------------
  # library_name / platform_library_name
  # ------------------------------------------------------------------

  def test_library_name_matches_the_platform
    name = LingoFuse.library_name
    assert_kind_of String, name
    refute_empty name

    case RbConfig::CONFIG['host_os']
    when /mswin|mingw|cygwin/i
      assert_match(/\ALingoFuse(32|64)\.dll\z/, name)
    when /darwin/i
      assert_equal 'liblingofuse.dylib', name
    else
      assert_equal 'liblingofuse.so', name
    end
  end

  def test_platform_library_name_is_consistent_with_library_name
    assert_equal LingoFuse.library_name, LingoFuse.platform_library_name
  end

  # ------------------------------------------------------------------
  # platform
  # ------------------------------------------------------------------

  def test_platform_returns_the_expected_keys
    info = LingoFuse.platform
    assert_kind_of Hash, info
    assert_equal %i[ruby platform library].sort, info.keys.sort
  end

  def test_platform_reports_the_running_ruby_version
    info = LingoFuse.platform
    assert_equal RUBY_VERSION, info[:ruby]
  end

  def test_platform_reports_the_running_platform
    info = LingoFuse.platform
    assert_equal RUBY_PLATFORM, info[:platform]
  end

  def test_platform_reports_a_library_name
    info = LingoFuse.platform
    assert_equal LingoFuse.library_name, info[:library]
  end

  # ------------------------------------------------------------------
  # cstr_ptr / read_cstr
  # ------------------------------------------------------------------

  def test_cstr_ptr_returns_a_fiddle_pointer
    ptr = LingoFuse.cstr_ptr('hello')
    assert_kind_of Fiddle::Pointer, ptr
    refute ptr.null?
  end

  def test_cstr_ptr_is_nul_terminated
    ptr = LingoFuse.cstr_ptr('abc')
    assert_equal 'a'.ord, ptr[0] & 0xFF
    assert_equal 'b'.ord, ptr[1] & 0xFF
    assert_equal 'c'.ord, ptr[2] & 0xFF
    assert_equal 0,       ptr[3] & 0xFF
  end

  def test_cstr_ptr_normalises_nil_to_empty_string
    ptr = LingoFuse.cstr_ptr(nil)
    assert_kind_of Fiddle::Pointer, ptr
    # Empty string is a single NUL.
    assert_equal 0, ptr[0] & 0xFF
  end

  def test_cstr_ptr_converts_non_strings
    ptr = LingoFuse.cstr_ptr(42)
    text = Fiddle::Pointer.new(ptr.to_i).to_s
    assert_equal '42', text
  end

  def test_cstr_ptr_handles_utf8
    ptr = LingoFuse.cstr_ptr('你好')
    # '你' is E4 BD A0 in UTF-8.
    assert_equal 0xE4, ptr[0] & 0xFF
    assert_equal 0xBD, ptr[1] & 0xFF
    assert_equal 0xA0, ptr[2] & 0xFF
    # '好' is E5 A5 BD in UTF-8.
    assert_equal 0xE5, ptr[3] & 0xFF
    assert_equal 0xA5, ptr[4] & 0xFF
    assert_equal 0xBD, ptr[5] & 0xFF
    # Framing NUL.
    assert_equal 0,    ptr[6] & 0xFF
  end

  def test_read_cstr_returns_empty_for_nil
    assert_equal '', LingoFuse.read_cstr(nil)
  end

  def test_read_cstr_returns_empty_for_zero
    assert_equal '', LingoFuse.read_cstr(0)
  end

  def test_read_cstr_reads_round_trip
    ptr = LingoFuse.cstr_ptr('hello, 世界 🌍')
    assert_equal 'hello, 世界 🌍', LingoFuse.read_cstr(ptr)
  end

  def test_read_cstr_accepts_integer_address
    ptr = LingoFuse.cstr_ptr('roundtrip')
    address = ptr.to_i
    assert_equal 'roundtrip', LingoFuse.read_cstr(address)
  end
end