# frozen_string_literal: true
#
# check_env.rb — Runtime-environment diagnostic for the LingoFuse Ruby binding.
#
# Run this BEFORE the test suite to verify that the installed runtime can:
#   1. Load the Ruby binding itself.
#   2. Load the native LingoFuse shared library through the C extension.
#   3. Create and round-trip a data handle at the C ABI boundary.
#   4. Register an app and perform a local Call round-trip.
#   5. Load the C-extension callback marshaling surface (NativeBridge).
#
# This script is intentionally independent of the test suite. It uses only
# the public API of the binding, so a failure here points at the runtime
# installation rather than at a specific test.
#
# Exit code:
#   0 — every check passed
#   1 — at least one required check failed
#
# Usage:
#   ruby check_env.rb
#
# All output is in English.
#
# ============================================================================

require 'rbconfig'

# ---------------------------------------------------------------------------
# Reporter
# ---------------------------------------------------------------------------

@passed = 0
@failed = 0
@warned = 0

def section(title)
  puts
  puts '=' * 72
  puts title
  puts '=' * 72
end

def ok(msg)
  puts "  [OK]   #{msg}"
  @passed += 1
end

def fail(msg)
  puts "  [FAIL] #{msg}"
  @failed += 1
end

def warn_(msg)
  puts "  [WARN] #{msg}"
  @warned += 1
end

def info(msg)
  puts "         #{msg}"
end

# ---------------------------------------------------------------------------
# Section 1 — Ruby runtime
# ---------------------------------------------------------------------------

section '1. Ruby runtime'

info "RUBY_VERSION       : #{RUBY_VERSION}"
info "RUBY_PLATFORM      : #{RUBY_PLATFORM}"
info "RbConfig host_os   : #{RbConfig::CONFIG['host_os']}"
info "RbConfig arch      : #{RbConfig::CONFIG['arch']}"
info "RbConfig bindir    : #{RbConfig::CONFIG['bindir']}"

if RUBY_PLATFORM =~ /mingw/
  ok 'Running under MinGW Ruby.'
else
  warn_ "RUBY_PLATFORM is '#{RUBY_PLATFORM}', not a MinGW build."
end

# ---------------------------------------------------------------------------
# Section 2 — Package layout
# ---------------------------------------------------------------------------
#
# The lib/ list below covers every source file that the entry point
# require's. It is deliberately exhaustive: a missing v2.0 file (for
# example, a partially-applied upgrade) shows up here before it can
# confuse a later section.
#
# The test/ list covers only a representative sample. The authoritative
# list of test files is in run_test_ci.ps1 / run_test_ci.sh; check_env
# does not duplicate it.

section '2. Package layout'

script_dir = File.dirname(File.expand_path(__FILE__))
lib_dir    = File.join(script_dir, 'lib')
test_dir   = File.join(script_dir, 'test')

lib_files = %w[
  lingofuse.rb
  lingofuse/errors.rb
  lingofuse/callback_error_reporter.rb
  lingofuse/binding.rb
  lingofuse/data_handle.rb
  lingofuse/app_handle.rb
  lingofuse/lf_io.rb
  lingofuse/framework.rb
  lingofuse/status.rb
  lingofuse/network_events.rb
  lingofuse/native_bridge.rb
  lingofuse/options.rb
  lingofuse/async_support.rb
  lingofuse/address.rb
  lingofuse/p2p_registration.rb
]

lib_files.each do |rel|
  path = File.join(lib_dir, rel)
  if File.file?(path)
    ok "Found: lib/#{rel}"
  else
    fail "Missing: lib/#{rel}"
  end
end

test_files = %w[
  test_errors.rb
  test_data_handle.rb
  test_app_handle.rb
  test_options.rb
  test_address.rb
  test_async_support.rb
  test_p2p_registration.rb
]

test_files.each do |rel|
  path = File.join(test_dir, rel)
  if File.file?(path)
    ok "Found: test/#{rel}"
  else
    fail "Missing: test/#{rel}"
  end
end

# ---------------------------------------------------------------------------
# Section 3 — Native library load and C ABI round-trip
# ---------------------------------------------------------------------------

section '3. Native library load and C ABI round-trip'

$LOAD_PATH.unshift(lib_dir) unless $LOAD_PATH.include?(lib_dir)

begin
  require 'lingofuse'
  ok 'require "lingofuse" succeeded.'
rescue StandardError, LoadError => e
  fail "require 'lingofuse' failed: #{e.class}: #{e.message}"
  section 'Report'
  puts "  Passed : #{@passed}"
  puts "  Warned : #{@warned}"
  puts "  Failed : #{@failed}"
  exit 1
end

if LingoFuse.loaded?
  ok 'LingoFuse.loaded? is true (native library resolved).'
else
  fail 'LingoFuse.loaded? is false (native library not found).'
end

info "Library name       : #{LingoFuse.library_name}"
info "Binding version    : #{LingoFuse::VERSION}"

if LingoFuse::NativeBridge.available?
  ok 'lingofuse_ext is loaded (NativeBridge available).'
else
  fail 'lingofuse_ext is NOT available (remote callbacks will not work).'
end

# --- v2.0 subsystem presence ----------------------------------------------
info = LingoFuse.platform

{
  has_async_support: 'AsyncSupport (CallFuture / AsyncBridge)',
  has_address:       'Address (AppTarget / UIDTarget / P2PNameTarget)',
  has_options:       'Options (16 typed set/get pairs)',
  has_p2p_reg:       'P2PRegistration (process-wide P2P API)'
}.each do |key, label|
  if info[key]
    ok "Subsystem loaded: #{label}"
  else
    fail "Subsystem MISSING: #{label}"
  end
end

# --- C ABI round-trip -----------------------------------------------------
begin
  h = LingoFuse::DataHandle.new('check_env_probe')
  ok 'DataHandle.new succeeded.'

  h.write_int32(0x1234)
  h.position = 0
  v = h.read_int32
  if v == 0x1234
    ok "DataHandle int32 round-trip: 0x1234 -> 0x#{v.to_s(16)}"
  else
    fail "DataHandle int32 round-trip mismatch: expected 0x1234, got 0x#{v.to_s(16)}"
  end

  h.position = 0
  h.write_string('hello, 世界')
  h.position = 0
  s = h.read_string
  if s == 'hello, 世界'
    ok "DataHandle UTF-8 round-trip: #{s.inspect}"
  else
    fail "DataHandle UTF-8 round-trip mismatch: got #{s.inspect}"
  end

  h.dispose
rescue StandardError => e
  fail "DataHandle round-trip raised: #{e.class}: #{e.message}"
end

# ---------------------------------------------------------------------------
# Section 4 — Full-stack smoke test
# ---------------------------------------------------------------------------

section '4. Full-stack smoke test'

begin
  app = LingoFuse::AppHandle.new(
    "check_env_#{Process.pid}_#{rand(1_000_000)}",
    'check_env smoke'
  )

  app.register_call('echo', 'echo') do |input, output|
    output.write_string(input.read_string)
  end
  ok 'AppHandle.new + register_call succeeded.'

  req = LingoFuse::DataHandle.new('echo')
  req.write_string('round-trip')
  res = app.local_call(req)
  got = res.read_string

  if got == 'round-trip'
    ok "local_call round-trip: #{got.inspect}"
  else
    fail "local_call round-trip mismatch: got #{got.inspect}"
  end

  req.dispose
  res.dispose
  app.dispose
rescue StandardError => e
  fail "Full-stack smoke raised: #{e.class}: #{e.message}"
end

# ---------------------------------------------------------------------------
# Section 5 — v2.0 subsystem quick probes
# ---------------------------------------------------------------------------
#
# These probes use only the public v2.0 surfaces and do not touch the
# network. They confirm that the four new modules are not just loaded
# (Section 3) but functionally callable.

section '5. v2.0 subsystem quick probes'

# --- Address constructors -------------------------------------------------
begin
  t = LingoFuse.app('check_env_probe')
  if t.is_a?(LingoFuse::Address::AppTarget)
    ok 'LingoFuse.app returns an AppTarget'
  else
    fail "LingoFuse.app returned #{t.class}"
  end

  u = LingoFuse.uid("\x00" * 32)
  if u.is_a?(LingoFuse::Address::UIDTarget)
    ok 'LingoFuse.uid returns a UIDTarget'
  else
    fail "LingoFuse.uid returned #{u.class}"
  end

  p = LingoFuse.p2pname('check_env_group')
  if p.is_a?(LingoFuse::Address::P2PNameTarget)
    ok 'LingoFuse.p2pname returns a P2PNameTarget'
  else
    fail "LingoFuse.p2pname returned #{p.class}"
  end
rescue StandardError => e
  fail "Address constructors raised: #{e.class}: #{e.message}"
end

# --- Options typed accessors ---------------------------------------------
begin
  original_quiet = LingoFuse.get_opt_quiet
  begin
    LingoFuse.set_opt_quiet(true)
    raise 'set_opt_quiet(true) did not stick' unless LingoFuse.get_opt_quiet == true
    LingoFuse.set_opt_quiet(false)
    raise 'set_opt_quiet(false) did not stick' unless LingoFuse.get_opt_quiet == false
    ok 'Options.set_opt_quiet / get_opt_quiet round-trip'
  ensure
    LingoFuse.set_opt_quiet(original_quiet)
  end

  snap = LingoFuse::Options.to_h
  if snap.is_a?(Hash) && snap.size == 16
    ok "Options.to_h returns 16 entries"
  else
    fail "Options.to_h returned #{snap.class} with size #{snap.respond_to?(:size) ? snap.size : '?'}"
  end
rescue StandardError => e
  fail "Options probe raised: #{e.class}: #{e.message}"
end

# --- AsyncSupport --------------------------------------------------------
begin
  f = LingoFuse::CallFuture.new
  f.fulfill(:ok)
  if f.value(timeout_ms: 100) == :ok
    ok 'CallFuture fulfil / value round-trip'
  else
    fail 'CallFuture.value did not return the fulfilled value'
  end

  bridge = LingoFuse::AsyncBridge.instance
  stats = bridge.stats
  if stats.is_a?(Hash) && stats.key?(:total)
    ok 'AsyncBridge.instance returns a bridge with a stats Hash'
  else
    fail "AsyncBridge.stats returned #{stats.inspect}"
  end
rescue StandardError => e
  fail "AsyncSupport probe raised: #{e.class}: #{e.message}"
end

# --- P2PRegistration (register + immediate unregister) -------------------
begin
  probe_name = "check_env_p2p_#{Process.pid}_#{rand(1_000_000)}"
  LingoFuse.register_p2p_call(probe_name, 'check_env probe') { |_i, _o| }
  registered = LingoFuse::P2PRegistration.registered?(probe_name)
  unregistered = LingoFuse.unregister_p2p(probe_name)

  if registered && unregistered
    ok 'P2PRegistration register / unregister round-trip'
  else
    fail "P2PRegistration probe failed: registered=#{registered}, unregistered=#{unregistered}"
  end
rescue StandardError => e
  fail "P2PRegistration probe raised: #{e.class}: #{e.message}"
end

# ---------------------------------------------------------------------------
# Section 6 — Report
# ---------------------------------------------------------------------------

section 'Report'

puts "  Passed : #{@passed}"
puts "  Warned : #{@warned}"
puts "  Failed : #{@failed}"
puts

if @failed.zero?
  puts '  All required checks passed.'
  puts
  exit 0
else
  puts "  #{@failed} required check(s) failed."
  puts '  Fix the issues above and run this script again.'
  puts
  exit 1
end