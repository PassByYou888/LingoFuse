# =============================================================================
#  run_tests.ps1
# -----------------------------------------------------------------------------
#  One-shot test runner for the LingoFuse Ruby binding on Windows.
#
#  Runs every check and test in order, stopping at the first failure.
#
#  Usage:
#
#      powershell -ExecutionPolicy Bypass -File run_tests.ps1
#
#  Exit code:
#
#      0   every step passed
#      1   at least one step failed
#
#  Required environment (set once per PowerShell session):
#
#      $env:LINGOFUSE_LIB_PATH = "D:\CoreLibrary\LingoFuse\Binary"
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
    Write-Host '       Fix the issues above and run this script again.'
    exit 1
}

# -----------------------------------------------------------------------------
# Step 2 — Test files, in dependency order
# -----------------------------------------------------------------------------
# The order is:
#   1. Tests that do not require the native library at all.
#   2. Tests that partially require it (JSON policy still runs).
#   3. Tests that fully require it.
#   4. Tests that specifically exercise the C extension.
#
# This makes a failure point at the layer where it actually occurred.
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
    'test/test_native_bridge_self_test.rb'
)

foreach ($t in $tests) {
    Write-Header "Step 2: Running $t"
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