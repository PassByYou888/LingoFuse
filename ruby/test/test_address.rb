# frozen_string_literal: true
#
# test_address.rb — Unit tests for LingoFuse::Address.
#
# ============================================================================
# COVERAGE
# ============================================================================
# This file exercises the three addressing modes in four layers:
#
#   1. TestAddressTargets
#        Pure-Ruby construction, equality, hashing, and describe output
#        for AppTarget / UIDTarget / P2PNameTarget.
#
#   2. TestUidNormalization
#        UID input handling: 32-byte raw, 64-char hex, uppercase hex,
#        and every rejected shape (short bytes, non-hex string, nil,
#        wrong type).
#
#   3. TestModuleConstructors
#        Module-level convenience constructors at both LingoFuse and
#        LingoFuse::Address scopes.
#
#   4. TestUnreachableCalls
#        Wire-level behaviour of call / call_future / notify against
#        a target name that does not exist on the mesh. These tests
#        require the native library; they are skipped when it is not
#        available.
#
# ============================================================================
# TESTING NOTES
# ============================================================================
# * Each test uses a unique target name so that the local C4 API
#   cache from one test cannot influence the next.
#
# * Unreachable-target tests use a short timeout (300 ms) so the whole
#   file finishes in well under two seconds.
#
# * All output is in English.
# ============================================================================

require 'minitest/autorun'
require 'securerandom'

_lib_dir = File.expand_path('../lib', __dir__)
$LOAD_PATH.unshift(_lib_dir) unless $LOAD_PATH.include?(_lib_dir)

begin
  require 'lingofuse'
rescue StandardError, LoadError => e
  warn "Failed to load LingoFuse: #{e.class}: #{e.message}"
end

# ======================================================================
# Helpers
# ======================================================================

module AddressTestHelper
  def unique_name(prefix)
    "#{prefix}_#{Process.pid}_#{SecureRandom.hex(4)}"
  end

  def zero_uid_bytes
    ("\x00" * 32).b
  end

  def zero_uid_hex
    '00' * 32
  end

  def sample_uid_bytes
    (0...32).map { |i| (i & 0xFF).chr }.join.b
  end

  def sample_uid_hex
    sample_uid_bytes.unpack1('H*')
  end
end

# ======================================================================
# Construction, equality, hashing, describe
# ======================================================================

class TestAddressTargets < Minitest::Test
  include AddressTestHelper

  def setup
    unless defined?(LingoFuse::Address)
      skip 'LingoFuse::Address not loaded'
    end
  end

  # ------------------------------------------------------------------
  # AppTarget
  # ------------------------------------------------------------------

  def test_app_target_construction
    t = LingoFuse::AppTarget.new('Calc')
    assert_equal 'Calc', t.app_name
    assert_equal 5000, t.default_timeout_ms
  end

  def test_app_target_custom_timeout
    t = LingoFuse::AppTarget.new('Calc', default_timeout_ms: 1234)
    assert_equal 1234, t.default_timeout_ms
  end

  def test_app_target_equality
    a = LingoFuse::AppTarget.new('Calc')
    b = LingoFuse::AppTarget.new('Calc')
    c = LingoFuse::AppTarget.new('Other')

    assert_equal a, b
    assert a.eql?(b)
    refute_equal a, c
  end

  def test_app_target_cross_type_not_equal
    a = LingoFuse::AppTarget.new('Calc')
    u = LingoFuse::UIDTarget.new(zero_uid_bytes)
    p = LingoFuse::P2PNameTarget.new('Calc')

    refute_equal a, u
    refute_equal a, p
    refute_equal a, 'Calc'
  end

  def test_app_target_hashable
    a = LingoFuse::AppTarget.new('Calc')
    b = LingoFuse::AppTarget.new('Calc')
    c = LingoFuse::AppTarget.new('Other')

    assert_equal a.hash, b.hash
    refute_equal a.hash, c.hash

    h = { a => 1 }
    assert_equal 1, h[b]
    assert_nil h[c]
  end

  def test_app_target_describe
    t = LingoFuse::AppTarget.new('MyApp')
    assert_equal 'app("MyApp")', t.describe
  end

  def test_app_target_rejects_nil
    assert_raises(ArgumentError) { LingoFuse::AppTarget.new(nil) }
  end

  # ------------------------------------------------------------------
  # UIDTarget
  # ------------------------------------------------------------------

  def test_uid_target_construction_from_bytes
    raw = sample_uid_bytes
    t = LingoFuse::UIDTarget.new(raw)
    assert_equal raw, t.uid
    assert_equal 32, t.uid.bytesize
    assert_equal Encoding::ASCII_8BIT, t.uid.encoding
  end

  def test_uid_target_construction_from_hex
    hex = sample_uid_hex
    t = LingoFuse::UIDTarget.new(hex)
    assert_equal sample_uid_bytes, t.uid
  end

  def test_uid_target_equality
    a = LingoFuse::UIDTarget.new(sample_uid_bytes)
    b = LingoFuse::UIDTarget.new(sample_uid_hex)
    c = LingoFuse::UIDTarget.new(zero_uid_bytes)

    assert_equal a, b
    refute_equal a, c
  end

  def test_uid_target_describe
    t = LingoFuse::UIDTarget.new(zero_uid_bytes)
    assert_equal "uid(#{zero_uid_hex})", t.describe
  end

  def test_uid_target_hashable
    a = LingoFuse::UIDTarget.new(sample_uid_bytes)
    b = LingoFuse::UIDTarget.new(sample_uid_hex)
    h = { a => :ok }
    assert_equal :ok, h[b]
  end

  # ------------------------------------------------------------------
  # P2PNameTarget
  # ------------------------------------------------------------------

  def test_p2pname_target_construction
    t = LingoFuse::P2PNameTarget.new('workers')
    assert_equal 'workers', t.group_name
    assert_equal 5000, t.default_timeout_ms
  end

  def test_p2pname_target_equality
    a = LingoFuse::P2PNameTarget.new('workers')
    b = LingoFuse::P2PNameTarget.new('workers')
    c = LingoFuse::P2PNameTarget.new('other')
    assert_equal a, b
    refute_equal a, c
  end

  def test_p2pname_target_describe
    t = LingoFuse::P2PNameTarget.new('workers')
    assert_equal 'p2pname("workers")', t.describe
  end

  def test_p2pname_target_rejects_nil
    assert_raises(ArgumentError) { LingoFuse::P2PNameTarget.new(nil) }
  end

  # ------------------------------------------------------------------
  # default_timeout_ms validation
  # ------------------------------------------------------------------

  def test_negative_timeout_rejected
    assert_raises(ArgumentError) do
      LingoFuse::AppTarget.new('Calc', default_timeout_ms: -1)
    end
  end

  def test_zero_timeout_accepted
    t = LingoFuse::AppTarget.new('Calc', default_timeout_ms: 0)
    assert_equal 0, t.default_timeout_ms
  end

  def test_string_timeout_coerced
    t = LingoFuse::AppTarget.new('Calc', default_timeout_ms: '5000')
    assert_equal 5000, t.default_timeout_ms
  end

  def test_non_numeric_timeout_rejected
    assert_raises(ArgumentError) do
      LingoFuse::AppTarget.new('Calc', default_timeout_ms: 'abc')
    end
  end

  def test_nil_timeout_rejected
    assert_raises(TypeError) do
      LingoFuse::AppTarget.new('Calc', default_timeout_ms: nil)
    end
  end

  # ------------------------------------------------------------------
  # Abstract base class
  # ------------------------------------------------------------------

  def test_target_base_class_cannot_be_used_directly
    t = LingoFuse::Target.new
    assert_raises(NotImplementedError) { t.call('api', nil) }
    assert_raises(NotImplementedError) { t.notify('api', nil) }
  end
end

# ======================================================================
# UID normalisation edge cases
# ======================================================================

class TestUidNormalization < Minitest::Test
  include AddressTestHelper

  def setup
    unless defined?(LingoFuse::UIDTarget)
      skip 'LingoFuse::UIDTarget not loaded'
    end
  end

  def test_32_byte_raw_accepted
    raw = sample_uid_bytes
    t = LingoFuse::UIDTarget.new(raw)
    assert_equal raw, t.uid
  end

  def test_64_char_hex_accepted
    hex = sample_uid_hex
    t = LingoFuse::UIDTarget.new(hex)
    assert_equal sample_uid_bytes, t.uid
  end

  def test_uppercase_hex_accepted
    hex = sample_uid_hex.upcase
    t = LingoFuse::UIDTarget.new(hex)
    assert_equal sample_uid_bytes, t.uid
  end

  def test_mixed_case_hex_accepted
    hex = sample_uid_hex
    mixed = hex.chars.each_with_index.map { |c, i| i.even? ? c.upcase : c }.join
    t = LingoFuse::UIDTarget.new(mixed)
    assert_equal sample_uid_bytes, t.uid
  end

  def test_short_bytes_rejected
    assert_raises(ArgumentError) do
      LingoFuse::UIDTarget.new('too short'.b)
    end
  end

  def test_long_bytes_rejected
    assert_raises(ArgumentError) do
      LingoFuse::UIDTarget.new('x' * 33)
    end
  end

  def test_empty_string_rejected
    assert_raises(ArgumentError) do
      LingoFuse::UIDTarget.new('')
    end
  end

  def test_non_hex_64_char_string_rejected
    # 64 characters, but contains letters outside [0-9a-fA-F].
    bad = 'z' * 64
    assert_raises(ArgumentError) do
      LingoFuse::UIDTarget.new(bad)
    end
  end

  def test_short_hex_string_rejected
    assert_raises(ArgumentError) do
      LingoFuse::UIDTarget.new('abcd')
    end
  end

  def test_wrong_type_rejected
    assert_raises(ArgumentError) { LingoFuse::UIDTarget.new(12_345) }
    assert_raises(ArgumentError) { LingoFuse::UIDTarget.new(:symbol) }
    assert_raises(ArgumentError) { LingoFuse::UIDTarget.new([]) }
  end

  def test_nil_rejected
    assert_raises(ArgumentError) { LingoFuse::UIDTarget.new(nil) }
  end
end

# ======================================================================
# Module-level constructors
# ======================================================================

class TestModuleConstructors < Minitest::Test
  include AddressTestHelper

  def setup
    unless defined?(LingoFuse::Address)
      skip 'LingoFuse::Address not loaded'
    end
  end

  def test_lingofuse_app
    t = LingoFuse.app('Calc')
    assert_instance_of LingoFuse::Address::AppTarget, t
    assert_equal 'Calc', t.app_name
  end

  def test_lingofuse_uid_from_bytes
    raw = sample_uid_bytes
    t = LingoFuse.uid(raw)
    assert_instance_of LingoFuse::Address::UIDTarget, t
    assert_equal raw, t.uid
  end

  def test_lingofuse_uid_from_hex
    hex = sample_uid_hex
    t = LingoFuse.uid(hex)
    assert_equal sample_uid_bytes, t.uid
  end

  def test_lingofuse_p2pname
    t = LingoFuse.p2pname('workers')
    assert_instance_of LingoFuse::Address::P2PNameTarget, t
    assert_equal 'workers', t.group_name
  end

  def test_address_module_app
    t = LingoFuse::Address.app('Calc')
    assert_instance_of LingoFuse::Address::AppTarget, t
  end

  def test_address_module_uid
    t = LingoFuse::Address.uid(sample_uid_bytes)
    assert_instance_of LingoFuse::Address::UIDTarget, t
  end

  def test_address_module_p2pname
    t = LingoFuse::Address.p2pname('workers')
    assert_instance_of LingoFuse::Address::P2PNameTarget, t
  end

  def test_custom_timeout_through_module_constructor
    t = LingoFuse.app('Calc', default_timeout_ms: 999)
    assert_equal 999, t.default_timeout_ms
  end
end

# ======================================================================
# Unreachable-target calls (requires the C extension)
# ======================================================================

class TestUnreachableCalls < Minitest::Test
  include AddressTestHelper

  def setup
    unless defined?(LingoFuse::AppTarget) && LingoFuse.loaded?
      skip 'native library not loaded; wire-level tests are skipped'
    end
  end

  # ------------------------------------------------------------------
  # Synchronous call
  # ------------------------------------------------------------------

  def test_call_to_missing_target_raises
    # The native layer returns a size-0 handle without running any
    # callback. The wrapper converts that into a TimeoutError.
    # Depending on the environment, it may instead surface as a
    # CallError (null handle). Both are acceptable.
    name = unique_name('missing_app')

    err = assert_raises(LingoFuse::Error) do
      LingoFuse.app(name).call('anything', nil, timeout_ms: 300)
    end

    assert(
      err.is_a?(LingoFuse::TimeoutError) || err.is_a?(LingoFuse::CallError),
      "expected TimeoutError or CallError, got #{err.class}"
    )
  end

  def test_call_with_payload_to_missing_target_raises
    name = unique_name('missing_app')

    assert_raises(LingoFuse::Error) do
      LingoFuse.app(name).call('anything', { 'k' => 'v' }, timeout_ms: 300)
    end
  end

  # ------------------------------------------------------------------
  # Asynchronous call
  # ------------------------------------------------------------------

  def test_call_future_returns_future
    name = unique_name('missing_app')

    future = LingoFuse.app(name).call_future('anything', nil, timeout_ms: 300)
    assert_instance_of LingoFuse::CallFuture, future

    # The future must eventually resolve (dispatch failure) or time
    # out (queued but never answered). Either outcome is fine; the
    # important invariant is that it does not hang forever.
    outcome = nil
    begin
      outcome = future.value(timeout_ms: 2000)
    rescue LingoFuse::Error
      # acceptable
    end

    assert(future.done? || future.abandoned?,
           'future must be resolved or marked abandoned within 2 s')
    # We do not assert on `outcome`: a dispatched-but-unanswered call
    # leaves it nil, while a dispatch failure raises before reaching
    # this point.
  end

  # ------------------------------------------------------------------
  # One-way notifications
  # ------------------------------------------------------------------

  def test_notify_to_missing_target_returns_nil
    name = unique_name('missing_app')
    result = LingoFuse.app(name).notify('anything', { 'k' => 'v' })
    assert_nil result
  end

  def test_sequenced_notify_to_missing_target_returns_nil
    name = unique_name('missing_app')
    result = LingoFuse.app(name).sequenced_notify('anything', { 'k' => 'v' })
    assert_nil result
  end

  # ------------------------------------------------------------------
  # P2PName and UID paths
  # ------------------------------------------------------------------

  def test_uid_call_to_missing_target_raises
    assert_raises(LingoFuse::Error) do
      LingoFuse.uid(zero_uid_bytes).call('anything', nil, timeout_ms: 300)
    end
  end

  def test_p2pname_call_to_missing_target_raises
    name = unique_name('missing_group')
    assert_raises(LingoFuse::Error) do
      LingoFuse.p2pname(name).call('anything', nil, timeout_ms: 300)
    end
  end

  def test_uid_notify_to_missing_target_returns_nil
    result = LingoFuse.uid(zero_uid_bytes).notify('anything', nil)
    assert_nil result
  end

  def test_p2pname_notify_to_missing_target_returns_nil
    name = unique_name('missing_group')
    result = LingoFuse.p2pname(name).notify('anything', nil)
    assert_nil result
  end
end