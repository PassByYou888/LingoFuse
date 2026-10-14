#!/usr/bin/env bash
#
# run_test_ci.sh — CI-oriented test runner for the LingoFuse Ruby binding
# on Linux, macOS, and any POSIX-compatible environment.
#
# Runs every check and test in order, stopping at the first failure.
#
# Exit status:
#     0   every step passed
#     1   at least one step failed
#
# Usage:
#
#     bash run_test_ci.sh
#
# Native library discovery:
#
#     The runtime binding resolves the LingoFuse native library
#     through the operating system's library search path ONLY:
#
#         Linux / BSD       LD_LIBRARY_PATH
#         macOS             DYLD_LIBRARY_PATH + DYLD_FALLBACK_LIBRARY_PATH
#
#     There is no binding-specific environment variable. Ensure the
#     directory that contains the native library is on the search path
#     before invoking this script. Example:
#
#         export LD_LIBRARY_PATH=/opt/lingofuse/lib:$LD_LIBRARY_PATH
#
# ============================================================================

set -u

header() {
    echo
    echo "========================================================================"
    echo "$1"
    echo "========================================================================"
}

# --- Step 1 — environment diagnostic ------------------------------------------

header "Step 1: Environment diagnostic (check_env.rb)"
if ! ruby check_env.rb; then
    echo
    echo "[FAIL] Environment diagnostic reported failures."
    exit 1
fi

# --- Step 2 — test files in dependency order ----------------------------------
#
# The order is:
#   1. Tests that do not require the native library at all.
#   2. Tests that partially require it (JSON policy still runs).
#   3. Tests that fully require it.
#   4. Tests that specifically exercise the C extension (run last).
#
# This makes a failure point at the layer where it actually occurred.
#
# The v2.0 additions (test_options, test_address, test_async_support,
# test_p2p_registration) are placed AFTER test_network but BEFORE
# test_native_bridge_self_test. Two of them exercise the C extension's
# callback-marshaling dispatcher; placing them just before the
# self-test keeps that cluster together.

tests=(
    "test/test_errors.rb"
    "test/test_callback_error_reporter.rb"
    "test/test_module_helpers.rb"
    "test/test_lf_io.rb"
    "test/test_lf_io_extra.rb"
    "test/test_data_handle.rb"
    "test/test_data_handle_extra.rb"
    "test/test_app_handle.rb"
    "test/test_app_handle_extra.rb"
    "test/test_status.rb"
    "test/test_network_events.rb"
    "test/test_framework.rb"
    "test/test_network.rb"
    "test/test_options.rb"
    "test/test_address.rb"
    "test/test_async_support.rb"
    "test/test_p2p_registration.rb"
    "test/test_native_bridge_self_test.rb"
)

for t in "${tests[@]}"; do
    header "Step 2: $t"
    if ! ruby "$t"; then
        echo
        echo "[FAIL] $t reported failures."
        exit 1
    fi
done

# --- Done ---------------------------------------------------------------------

echo
echo "========================================================================"
echo "All ${#tests[@]} test files passed."
echo "========================================================================"
exit 0