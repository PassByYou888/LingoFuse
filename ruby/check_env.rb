#!/usr/bin/env ruby
# frozen_string_literal: true
#
# check_env.rb — Environment diagnostic for the LingoFuse Ruby binding.
#
# Verifies, in order:
#
#   1. Ruby runtime
#   2. Package layout
#   3. Native library load and C ABI round trip
#   4. Full-stack smoke test
#
# No external gem is required. The binding uses Fiddle from the standard
# library.
#
# Exit status:
#   0   all required checks passed
#   1   at least one check failed
#

module Reporter
  @pass_count = 0
  @fail_count = 0

  class << self
    def pass_count; @pass_count; end
    def fail_count; @fail_count; end

    def section(title)
      puts ''
      puts '=' * 72
      puts title
      puts '=' * 72
    end

    def ok(msg)
      puts "  [OK]   #{msg}"
      @pass_count += 1
    end

    def fail(msg)
      puts "  [FAIL] #{msg}"
      @fail_count += 1
    end

    def info(msg)
      puts "         #{msg}"
    end
  end
end

script_dir = File.expand_path(__dir__)

# ============================================================================
# Section 0 — Load path
# ============================================================================
#
# lib/ MUST be on $LOAD_PATH before any require of the binding. Without
# this, `require 'lingofuse'` still works (it is loaded by absolute
# path below), but the C extension `lingofuse_ext.so` lives in lib/ and
# is required by native_bridge.rb through a bare name. That bare-name
# require only consults $LOAD_PATH, so the extension would silently
# fail to load and every callback path would fall back to the Fiddle
# stub.
#
# Adding lib/ here makes the diagnostic accurate: if the extension is
# present in lib/, this script will load it.

lib_dir = File.join(script_dir, 'lib')
$LOAD_PATH.unshift(lib_dir) unless $LOAD_PATH.include?(lib_dir)

# ============================================================================
# Section 1 — Ruby runtime
# ============================================================================

Reporter.section('1. Ruby runtime')

Reporter.info "Ruby version    : #{RUBY_VERSION}"
Reporter.info "Ruby platform   : #{RUBY_PLATFORM}"
Reporter.info "Working dir     : #{Dir.pwd}"

if RUBY_VERSION >= '2.7.0'
  Reporter.ok "Ruby version #{RUBY_VERSION} satisfies the >= 2.7.0 requirement."
else
  Reporter.fail "Ruby #{RUBY_VERSION} is older than the required 2.7.0."
end

# ============================================================================
# Section 2 — Package layout
# ============================================================================

Reporter.section('2. Package layout')

EXPECTED_LIB_FILES = %w[
  lib/lingofuse.rb
  lib/lingofuse/errors.rb
  lib/lingofuse/binding.rb
  lib/lingofuse/callback_error_reporter.rb
  lib/lingofuse/native_bridge.rb
  lib/lingofuse/data_handle.rb
  lib/lingofuse/app_handle.rb
  lib/lingofuse/lf_io.rb
  lib/lingofuse/framework.rb
  lib/lingofuse/status.rb
  lib/lingofuse/network_events.rb
].freeze

EXPECTED_TEST_FILES = %w[
  test/test_lf_io.rb
  test/test_data_handle.rb
  test/test_app_handle.rb
].freeze

EXPECTED_LIB_FILES.each do |rel|
  abs = File.join(script_dir, rel)
  if File.file?(abs)
    Reporter.ok "Found: #{rel}"
  else
    Reporter.fail "Missing: #{rel}"
  end
end

EXPECTED_TEST_FILES.each do |rel|
  abs = File.join(script_dir, rel)
  if File.file?(abs)
    Reporter.ok "Found: #{rel}"
  else
    Reporter.fail "Missing: #{rel}"
  end
end

# ============================================================================
# Section 3 — Native library load and C ABI round trip
# ============================================================================

Reporter.section('3. Native library load and C ABI round trip')

binding_loaded = false

begin
  require File.join(script_dir, 'lib', 'lingofuse', 'binding')
  Reporter.ok "require 'lingofuse/binding' succeeded."

  hnd = LingoFuse::LF_CreateData.call(
    LingoFuse.cstr_ptr('check_env_raw')
  )

  # The C ABI returns a void*; a null pointer has to_i == 0.
  if hnd.nil? || hnd.to_i.zero?
    Reporter.fail 'LF_CreateData returned a null handle.'
  else
    Reporter.ok 'LF_CreateData returned a non-null handle.'

    payload = "\x01\x02\x03\x04".b
    in_ptr = Fiddle::Pointer.malloc(payload.bytesize)
    in_ptr[0, payload.bytesize] = payload

    written = LingoFuse::LF_WriteBuffer.call(
      hnd, in_ptr, payload.bytesize
    )

    if written == payload.bytesize
      Reporter.ok "LF_WriteBuffer wrote #{written} bytes."
    else
      Reporter.fail "LF_WriteBuffer wrote #{written} of #{payload.bytesize} bytes."
    end

    LingoFuse::LF_SetPos.call(hnd, 0)

    out_ptr = Fiddle::Pointer.malloc(payload.bytesize)
    read = LingoFuse::LF_ReadBuffer.call(hnd, out_ptr, payload.bytesize)

    if read == payload.bytesize && out_ptr.to_s(payload.bytesize) == payload
      Reporter.ok 'LF_ReadBuffer returned the exact bytes written.'
    else
      Reporter.fail 'LF_ReadBuffer mismatch.'
    end

    LingoFuse::LF_FreeData.call(hnd)
    Reporter.ok 'LF_FreeData released the handle.'
  end

  binding_loaded = true
rescue StandardError, LoadError => e
  Reporter.fail "Could not load the native library: #{e.class}"
  Reporter.info e.message.to_s.lines.first(6).map(&:chomp).join("\n         ")
  binding_loaded = false
end

# ============================================================================
# Section 4 — Full-stack smoke test
# ============================================================================

Reporter.section('4. Full-stack smoke test')

if binding_loaded
  begin
    require File.join(script_dir, 'lib', 'lingofuse')
    Reporter.ok "require 'lingofuse' (full stack) succeeded."
  rescue StandardError => e
    Reporter.fail "require 'lingofuse' failed: #{e.class}: #{e.message}"
  end
end

# --- C extension load status ---------------------------------------------
#
# Reported separately so that a missing lingofuse_ext is visible in the
# diagnostic output. The extension is OPTIONAL for pure-local usage but
# REQUIRED for remote callbacks (see BUILD_EXTENSION.md).

if defined?(LingoFuse::NativeBridge)
  if LingoFuse::NativeBridge.available?
    Reporter.ok 'lingofuse_ext is loaded (NativeBridge available).'
  else
    Reporter.fail 'lingofuse_ext is NOT available. Remote callbacks will not work.'
    Reporter.info 'Build it with: powershell -File setup_build_env.ps1'
    Reporter.info 'Then re-run this diagnostic.'
  end
end

# --- DataHandle -----------------------------------------------------------
if binding_loaded && defined?(LingoFuse::DataHandle)
  begin
    dh = LingoFuse::DataHandle.new('check_env_dh')
    dh.write_int32(42)
    dh.position = 0
    value = dh.read_int32
    dh.dispose
    value == 42 ? Reporter.ok('DataHandle scalar round trip OK.')
                : Reporter.fail("DataHandle scalar mismatch: #{value.inspect}")

    dh = LingoFuse::DataHandle.new('check_env_str')
    dh.write_string('你好, 🌍')
    dh.position = 0
    text = dh.read_string
    dh.dispose
    text == '你好, 🌍' ? Reporter.ok('DataHandle string round trip OK.')
                       : Reporter.fail("DataHandle string mismatch: #{text.inspect}")
  rescue StandardError => e
    Reporter.fail "DataHandle smoke test failed: #{e.class}: #{e.message}"
  end
end

# --- AppHandle ------------------------------------------------------------
if binding_loaded && defined?(LingoFuse::AppHandle)
  begin
    app = LingoFuse::AppHandle.new('check_env_app', 'diagnostic')
    app.register_call('ping', 'diagnostic ping') do |_input, output|
      output.write_int32(99)
    end

    req = LingoFuse::DataHandle.new('ping')
    res = app.local_call(req)
    value = res.read_int32

    res.dispose
    req.dispose
    app.dispose

    value == 99 ? Reporter.ok('AppHandle local_call round trip OK.')
                : Reporter.fail("AppHandle local_call mismatch: #{value.inspect}")
  rescue StandardError => e
    Reporter.fail "AppHandle smoke test failed: #{e.class}: #{e.message}"
  end
end

# --- LfIo JSON policy -----------------------------------------------------
if defined?(LingoFuse::LfIo)
  begin
    text = LingoFuse::LfIo.dumps_json({ 'msg' => '你好' })
    if text.include?('你好') && !text.include?('\\u')
      Reporter.ok 'LfIo JSON policy OK (non-ASCII emitted literally).'
    else
      Reporter.fail "LfIo JSON policy violated: #{text.inspect}"
    end
  rescue StandardError => e
    Reporter.fail "LfIo smoke test failed: #{e.class}: #{e.message}"
  end
end

# ============================================================================
# Section 5 — Report
# ============================================================================

Reporter.section('5. Report')

puts "  Passed : #{Reporter.pass_count}"
puts "  Failed : #{Reporter.fail_count}"
puts ''

exit(Reporter.fail_count.zero? ? 0 : 1)