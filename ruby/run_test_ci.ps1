# =============================================================================
#  run_test_ci.ps1
# -----------------------------------------------------------------------------
#  CI-oriented test runner for the LingoFuse Ruby binding on Windows.
#
#  Runs every check and test in order, stopping at the first failure.
#
#  Exit code:
#
#      0   every step passed
#      1   at least one step failed
#
#  Usage:
#
#      powershell -ExecutionPolicy Bypass -File run_test_ci.ps1
#
#  Native library discovery:
#
#      The runtime binding resolves the LingoFuse native library
#      (LingoFuse64.dll and its three siblings) through the operating
#      system's library search path ONLY:
#
#          Windows           PATH
#          Linux / BSD       LD_LIBRARY_PATH
#          macOS             DYLD_LIBRARY_PATH + DYLD_FALLBACK_LIBRARY_PATH
#
#      There is no binding-specific environment variable. In a CI job,
#      ensure the directory that contains the native library is on PATH
#      before invoking this script. Example (PowerShell):
#
#          $env:PATH = "D:\LingoFuse\Binary;" + $env:PATH
#
#      The four DLLs must live in the same directory, because
#      LingoFuse64.dll loads its siblings by name at load time.
#
#  This script is functionally identical to run_tests.ps1. The two
#  files are kept separate so that a future change (for example,
#  adding an HTML report or a JUnit XML output) can be applied to the
#  CI path without touching the interactive developer experience.
#
# =============================================================================

$ErrorActionPreference = 'Continue'

function Write-Header {
    param([string]$Title)
    Write-Host ''
    Write-Host ('=' * 72)
    Write-Host $Title
    Write-Host ('=' * 72)
}

# -----------------------------------------------------------------------------
# Step 1 — Environment diagnostic
# -----------------------------------------------------------------------------

Write-Header 'Step 1: Environment diagnostic (check_env.rb)'
ruby check_env.rb
if ($LASTEXITCODE -ne 0) {
    Write-Host ''
    Write-Host '[FAIL] Environment diagnostic reported failures.'
    exit 1
}

# -----------------------------------------------------------------------------
# Step 2 — Test files, in dependency order
# -----------------------------------------------------------------------------
#
# The order is:
#   1. Tests that do not require the native library at all.
#   2. Tests that partially require it (JSON policy still runs).
#   3. Tests that fully require it.
#   4. Tests that specifically exercise the C extension.
#
# This makes a failure point at the layer where it actually occurred.
#
# The v2.0 additions (test_options, test_address, test_async_support,
# test_p2p_registration) are placed AFTER test_network but BEFORE
# test_native_bridge_self_test. Two of them (async_support,
# p2p_registration) exercise the C extension's callback-marshaling
# dispatcher under realistic load; placing them just before the
# self-test keeps that cluster together.
#
# `test_native_bridge_self_test.rb` is intentionally placed LAST: it
# is the only file that exercises the C extension in isolation, and
# running it after the network tests guarantees those tests have
# already exercised the dispatcher under realistic load.
# -----------------------------------------------------------------------------

$tests = @(
    'test/test_errors.rb',
    'test/test_callback_error_reporter.rb',
    'test/test_module_helpers.rb',
    'test/test_lf_io.rb',
    'test/test_lf_io_extra.rb',
    'test/test_data_handle.rb',
    'test/test_data_handle_extra.rb',
    'test/test_app_handle.rb',
    'test/test_app_handle_extra.rb',
    'test/test_status.rb',
    'test/test_network_events.rb',
    'test/test_framework.rb',
    'test/test_network.rb',
    'test/test_options.rb',
    'test/test_address.rb',
    'test/test_async_support.rb',
    'test/test_p2p_registration.rb',
    'test/test_native_bridge_self_test.rb'
)

foreach ($t in $tests) {
    Write-Header "Step 2: $t"
    ruby $t
    if ($LASTEXITCODE -ne 0) {
        Write-Host ''
        Write-Host "[FAIL] $t reported failures."
        exit 1
    }
}

# -----------------------------------------------------------------------------
# Done
# -----------------------------------------------------------------------------

Write-Host ''
Write-Host ('=' * 72)
Write-Host "All $($tests.Count) test files passed."
Write-Host ('=' * 72)
exit 0