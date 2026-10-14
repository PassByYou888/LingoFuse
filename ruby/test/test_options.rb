# frozen_string_literal: true
#
# test_options.rb — Unit tests for LingoFuse::Options.
#
# ============================================================================
# COVERAGE
# ============================================================================
# Six test classes cover the typed option surface:
#
#   1. TestOptionBooleans
#        All five boolean options round-trip through set / get and
#        accept truthy / falsy Ruby values.
#
#   2. TestOptionIntegers
#        All integer options round-trip and preserve a range of
#        values (zero, small positive, large positive, and the uint32
#        maximum).
#
#   3. TestOptionStrings
#        String options round-trip and reset to "". The password
#        getter returns the library's fixed mask. The debug getter
#        returns the library's fixed placeholder.
#
#   4. TestOptionsToH
#        The diagnostics snapshot covers every option and returns the
#        correct Ruby type for each.
#
#   5. TestOptionTopLevelAliases
#        Every option is also reachable through a LingoFuse.set_opt_*
#        / LingoFuse.get_opt_* top-level method.
#
#   6. TestNoReponseSpelling
#        The historical spelling "No_Reponse" (without the second 's')
#        is preserved in the option key.
#
# ============================================================================
# TESTING NOTES
# ============================================================================
# * Every test class snapshots the options it touches in `setup` and
#   restores them in `teardown`. This keeps the process's runtime
#   configuration stable across the whole suite.
#
# * The underlying library resets every option on LF_Shutdown, so
#   restoring values after each test is sufficient to isolate tests
#   within a single Ruby process.
#
# * The Pascal-side integer options are all unsigned (uint64_t). A
#   negative Ruby Integer would be reinterpreted as a large unsigned
#   value by the C `strtoull` call used on the native side. The tests
#   therefore never feed a negative value to an integer option; they
#   exercise zero, small positive, and the uint32 maximum instead.
#
# * Options are process-global; when LingoFuse is not loaded, every
#   test is skipped with a clear message.
#
# All output is in English.
# ============================================================================

require 'minitest/autorun'

_lib_dir = File.expand_path('../lib', __dir__)
$LOAD_PATH.unshift(_lib_dir) unless $LOAD_PATH.include?(_lib_dir)

begin
  require 'lingofuse'
rescue StandardError, LoadError => e
  warn "Failed to load LingoFuse: #{e.class}: #{e.message}"
end

# ======================================================================
# Common base class
# ======================================================================

class OptionTestBase < Minitest::Test
  def setup
    unless defined?(LingoFuse::Options) && LingoFuse.loaded?
      skip 'native library not loaded; option tests are skipped'
    end
  end

  # Snapshot the values of the listed option readers; return a Hash of
  # setter closures to restore them. The caller registers the restore
  # closures with `restore_after`.
  #
  # The list uses the SHORT names (without the set_opt_ / get_opt_
  # prefixes). Each name corresponds to a matching pair of methods on
  # LingoFuse::Options.
  def snapshot_options(*short_names)
    snapshots = {}
    short_names.each do |name|
      getter = "get_opt_#{name}"
      setter = "set_opt_#{name}"
      snapshots[name] = {
        getter: getter,
        setter: setter,
        value: LingoFuse::Options.public_send(getter)
      }
    end
    snapshots
  end

  def restore_options(snapshots)
    snapshots.each do |_name, info|
      LingoFuse::Options.public_send(info[:setter], info[:value])
    rescue StandardError
      # ignored: teardown must not mask a test failure
    end
  end
end

# ======================================================================
# Boolean options
# ======================================================================

class TestOptionBooleans < OptionTestBase
  BOOLEAN_OPTIONS = %i[
    quiet
    show_thread_id
    console_output
    overlap_connection
    wait_connection_ready_ok
  ].freeze

  def setup
    super
    @snapshots = snapshot_options(*BOOLEAN_OPTIONS)
  end

  def teardown
    restore_options(@snapshots) if @snapshots
  end

  BOOLEAN_OPTIONS.each do |name|
    define_method("test_#{name}_true_roundtrip") do
      setter = "set_opt_#{name}"
      getter = "get_opt_#{name}"
      LingoFuse::Options.public_send(setter, true)
      assert_equal true, LingoFuse::Options.public_send(getter)
    end

    define_method("test_#{name}_false_roundtrip") do
      setter = "set_opt_#{name}"
      getter = "get_opt_#{name}"
      LingoFuse::Options.public_send(setter, false)
      assert_equal false, LingoFuse::Options.public_send(getter)
    end

    define_method("test_#{name}_truthy_value_is_coerced") do
      setter = "set_opt_#{name}"
      getter = "get_opt_#{name}"
      LingoFuse::Options.public_send(setter, 'yes')
      assert_equal true, LingoFuse::Options.public_send(getter)
    end

    define_method("test_#{name}_falsy_value_is_coerced") do
      setter = "set_opt_#{name}"
      getter = "get_opt_#{name}"
      LingoFuse::Options.public_send(setter, nil)
      assert_equal false, LingoFuse::Options.public_send(getter)
    end
  end
end

# ======================================================================
# Integer options
# ======================================================================

class TestOptionIntegers < OptionTestBase
  INTEGER_OPTIONS = %i[
    wait_connection_timeout
    ipc_serv_thread_count
    ipc_serv_max_queue_length
    ipc_serv_max_msg_size
    fixed_sequenced_time
    data_handle_idle_timeout
    data_handle_pool_scan_interval
    no_reponse_cmd_null_flush_threshold
  ].freeze

  def setup
    super
    @snapshots = snapshot_options(*INTEGER_OPTIONS)
  end

  def teardown
    restore_options(@snapshots) if @snapshots
  end

  INTEGER_OPTIONS.each do |name|
    define_method("test_#{name}_zero_roundtrip") do
      setter = "set_opt_#{name}"
      getter = "get_opt_#{name}"
      LingoFuse::Options.public_send(setter, 0)
      assert_equal 0, LingoFuse::Options.public_send(getter)
    end

    define_method("test_#{name}_small_roundtrip") do
      setter = "set_opt_#{name}"
      getter = "get_opt_#{name}"
      LingoFuse::Options.public_send(setter, 42)
      assert_equal 42, LingoFuse::Options.public_send(getter)
    end

    define_method("test_#{name}_large_roundtrip") do
      setter = "set_opt_#{name}"
      getter = "get_opt_#{name}"
      LingoFuse::Options.public_send(setter, 1_000_000)
      assert_equal 1_000_000, LingoFuse::Options.public_send(getter)
    end

    define_method("test_#{name}_string_value_coerced") do
      setter = "set_opt_#{name}"
      getter = "get_opt_#{name}"
      LingoFuse::Options.public_send(setter, '1234')
      assert_equal 1234, LingoFuse::Options.public_send(getter)
    end

    define_method("test_#{name}_malformed_value_rejected") do
      setter = "set_opt_#{name}"
      assert_raises(ArgumentError) do
        LingoFuse::Options.public_send(setter, 'not a number')
      end
    end
  end

  # ------------------------------------------------------------------
  # uint32 maximum round-trip.
  #
  # All Pascal-side integer options are unsigned (uint64_t). A value
  # inside the uint32 range is safe for every one of them and well
  # below the clamp thresholds applied by the underlying library.
  #
  # We do NOT test negative values: the C side uses strtoull, which
  # would reinterpret a negative Ruby Integer as a very large uint64.
  # That behaviour is a property of the C library, not of this
  # wrapper, and does not belong in a typed-wrapper test.
  # ------------------------------------------------------------------

  def test_uint32_max_value_roundtrip
    name   = :data_handle_idle_timeout
    setter = "set_opt_#{name}"
    getter = "get_opt_#{name}"

    uint32_max = 4_294_967_295
    LingoFuse::Options.public_send(setter, uint32_max)
    assert_equal uint32_max, LingoFuse::Options.public_send(getter)
  end
end

# ======================================================================
# String options
# ======================================================================

class TestOptionStrings < OptionTestBase
  STRING_OPTIONS = %i[
    p2p_name
  ].freeze

  def setup
    super
    @snapshots = snapshot_options(*STRING_OPTIONS)
  end

  def teardown
    restore_options(@snapshots) if @snapshots
  end

  def test_p2p_name_roundtrip
    LingoFuse::Options.set_opt_p2p_name('workers')
    assert_equal 'workers', LingoFuse::Options.get_opt_p2p_name
  end

  def test_p2p_name_reset_to_empty
    LingoFuse::Options.set_opt_p2p_name('workers')
    LingoFuse::Options.set_opt_p2p_name('')
    assert_equal '', LingoFuse::Options.get_opt_p2p_name
  end

  def test_p2p_name_utf8_roundtrip
    LingoFuse::Options.set_opt_p2p_name('worker_组')
    got = LingoFuse::Options.get_opt_p2p_name

    # The C extension must return UTF-8 encoded strings, not raw bytes.
    # This assertion pins that contract.
    assert_equal 'worker_组', got
    assert_equal Encoding::UTF_8, got.encoding
  end

  def test_p2p_name_nil_becomes_empty
    LingoFuse::Options.set_opt_p2p_name(nil)
    assert_equal '', LingoFuse::Options.get_opt_p2p_name
  end

  # ------------------------------------------------------------------
  # Password is always masked
  # ------------------------------------------------------------------

  def test_password_is_always_masked
    LingoFuse::Options.set_opt_password('secret')
    # The library returns a fixed mask, never the real value.
    assert_equal '********', LingoFuse::Options.get_opt_password
  end

  # ------------------------------------------------------------------
  # Debug is write-only; getter returns a placeholder
  # ------------------------------------------------------------------

  def test_debug_getter_returns_placeholder
    # Setting debug executes a console command; we set an empty value
    # so nothing is actually executed.
    LingoFuse::Options.set_opt_debug('')
    v = LingoFuse::Options.get_opt_debug
    assert_kind_of String, v
    # The library returns a fixed placeholder for write-only options.
    refute_nil v
  end
end

# ======================================================================
# to_h snapshot
# ======================================================================

class TestOptionsToH < OptionTestBase
  EXPECTED_KEYS = %i[
    password
    debug
    quiet
    show_thread_id
    console_output
    overlap_connection
    wait_connection_ready_ok
    wait_connection_timeout
    ipc_serv_thread_count
    ipc_serv_max_queue_length
    ipc_serv_max_msg_size
    fixed_sequenced_time
    p2p_name
    data_handle_idle_timeout
    data_handle_pool_scan_interval
    no_reponse_cmd_null_flush_threshold
  ].freeze

  def test_to_h_returns_hash
    h = LingoFuse::Options.to_h
    assert_kind_of Hash, h
  end

  def test_to_h_has_every_expected_key
    h = LingoFuse::Options.to_h
    EXPECTED_KEYS.each do |key|
      assert h.key?(key), "to_h must contain key #{key.inspect}"
    end
  end

  def test_to_h_key_count_matches_expected
    h = LingoFuse::Options.to_h
    assert_equal EXPECTED_KEYS.size, h.size,
                 'to_h must return exactly one entry per option'
  end

  def test_to_h_value_types
    h = LingoFuse::Options.to_h

    assert_kind_of String, h[:password]
    assert_kind_of String, h[:debug]
    assert_includes [true, false], h[:quiet]
    assert_includes [true, false], h[:show_thread_id]
    assert_includes [true, false], h[:console_output]
    assert_includes [true, false], h[:overlap_connection]
    assert_includes [true, false], h[:wait_connection_ready_ok]
    assert_kind_of Integer, h[:wait_connection_timeout]
    assert_kind_of Integer, h[:ipc_serv_thread_count]
    assert_kind_of Integer, h[:ipc_serv_max_queue_length]
    assert_kind_of Integer, h[:ipc_serv_max_msg_size]
    assert_kind_of Integer, h[:fixed_sequenced_time]
    assert_kind_of String,  h[:p2p_name]
    assert_kind_of Integer, h[:data_handle_idle_timeout]
    assert_kind_of Integer, h[:data_handle_pool_scan_interval]
    assert_kind_of Integer, h[:no_reponse_cmd_null_flush_threshold]
  end

  def test_to_h_reflects_current_values
    original = LingoFuse::Options.get_opt_quiet
    begin
      LingoFuse::Options.set_opt_quiet(true)
      assert_equal true, LingoFuse::Options.to_h[:quiet]

      LingoFuse::Options.set_opt_quiet(false)
      assert_equal false, LingoFuse::Options.to_h[:quiet]
    ensure
      LingoFuse::Options.set_opt_quiet(original)
    end
  end
end

# ======================================================================
# Top-level aliases
# ======================================================================

class TestOptionTopLevelAliases < OptionTestBase
  def test_all_set_get_pairs_respond_to_top_level
    %i[
      password debug quiet show_thread_id console_output
      overlap_connection wait_connection_ready_ok wait_connection_timeout
      ipc_serv_thread_count ipc_serv_max_queue_length ipc_serv_max_msg_size
      fixed_sequenced_time p2p_name
      data_handle_idle_timeout data_handle_pool_scan_interval
      no_reponse_cmd_null_flush_threshold
    ].each do |name|
      assert_respond_to LingoFuse, "set_opt_#{name}",
                        "LingoFuse must respond to set_opt_#{name}"
      assert_respond_to LingoFuse, "get_opt_#{name}",
                        "LingoFuse must respond to get_opt_#{name}"
    end
  end

  def test_top_level_bool_roundtrip
    original = LingoFuse.get_opt_quiet
    begin
      LingoFuse.set_opt_quiet(true)
      assert_equal true, LingoFuse.get_opt_quiet
      LingoFuse.set_opt_quiet(false)
      assert_equal false, LingoFuse.get_opt_quiet
    ensure
      LingoFuse.set_opt_quiet(original)
    end
  end

  def test_top_level_int_roundtrip
    original = LingoFuse.get_opt_wait_connection_timeout
    begin
      LingoFuse.set_opt_wait_connection_timeout(7777)
      assert_equal 7777, LingoFuse.get_opt_wait_connection_timeout
    ensure
      LingoFuse.set_opt_wait_connection_timeout(original)
    end
  end

  def test_top_level_string_roundtrip
    original = LingoFuse.get_opt_p2p_name
    begin
      LingoFuse.set_opt_p2p_name('alias_group')
      assert_equal 'alias_group', LingoFuse.get_opt_p2p_name
    ensure
      LingoFuse.set_opt_p2p_name(original)
    end
  end
end

# ======================================================================
# Historical spelling
# ======================================================================

class TestNoReponseSpelling < OptionTestBase
  # The option key uses "Reponse" (no second 's'), matching the Pascal
  # side. Getting the spelling wrong means the underlying library
  # silently ignores the value, and the getter returns the fallback
  # (0 for an integer). This test pins the correct spelling.

  def test_correct_spelling_roundtrips
    original = LingoFuse::Options.get_opt_no_reponse_cmd_null_flush_threshold
    begin
      LingoFuse::Options.set_opt_no_reponse_cmd_null_flush_threshold(1234)
      assert_equal 1234,
                   LingoFuse::Options.get_opt_no_reponse_cmd_null_flush_threshold
    ensure
      LingoFuse::Options.set_opt_no_reponse_cmd_null_flush_threshold(original)
    end
  end

  def test_setter_responds_only_to_correct_spelling
    assert_respond_to LingoFuse::Options,
                      :set_opt_no_reponse_cmd_null_flush_threshold
    refute_respond_to LingoFuse::Options,
                      :set_opt_no_response_cmd_null_flush_threshold
  end
end