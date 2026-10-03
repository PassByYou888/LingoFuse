# =============================================================================
#  test.ps1 - Run the complete LingoFuse Zig test suite.
# -----------------------------------------------------------------------------
#  Test suites
#  -----------
#    test                  - Zig-native unit test suite (33 tests).
#    smoke                 - ABI smoke test as a normal program.
#    io-smoke              - Unified I/O smoke test.
#    json-smoke            - lf_json C ABI smoke test.
#    network-events-smoke  - Network event install / query / clear.
#    status-smoke          - Status queue helpers.
#
#  Why these are smoke programs, not Zig unit tests
#  ------------------------------------------------
#  The Zig test runner on Windows can hang when the native LingoFuse
#  library writes diagnostics to the console. Most suites therefore run
#  as normal executables whose output is written to a log file before
#  and after each native call. This script invokes them through
#  `zig build`, collects their exit codes, and prints a summary.
#
#  Parameters
#  ----------
#    -Optimize   Selects the Zig optimization mode (Debug by default).
#    -Quiet      Suppresses per-step progress output. Only the final
#                summary is printed.
#
#  Exit codes
#  ----------
#    0  every suite passed
#    1  the Zig toolchain is not available
#    2  at least one suite failed
#
#  Example
#  -------
#    .\test.ps1
#    .\test.ps1 -Optimize ReleaseFast
#    .\test.ps1 -Quiet
# =============================================================================

[CmdletBinding()]
param(
    [ValidateSet('Debug', 'ReleaseSafe', 'ReleaseFast', 'ReleaseSmall')]
    [string]$Optimize = 'Debug',

    [switch]$Quiet
)

$ErrorActionPreference = 'Stop'

# -----------------------------------------------------------------------------
# Helpers.
# -----------------------------------------------------------------------------
function Write-Status {
    param(
        [string]$Message,
        [string]$Color = 'Cyan'
    )
    if (-not $Quiet) {
        Write-Host $Message -ForegroundColor $Color
    }
}

function Write-Always {
    param(
        [string]$Message,
        [string]$Color = 'White'
    )
    Write-Host $Message -ForegroundColor $Color
}

# -----------------------------------------------------------------------------
# Move to the script's own directory.
# -----------------------------------------------------------------------------
$Root = $PSScriptRoot
Set-Location $Root

# -----------------------------------------------------------------------------
# Suite table. Order matters: the unit test suite runs first, then the
# smoke programs from lowest to highest layer.
# -----------------------------------------------------------------------------
$suites = @(
    @{ Step = 'test';                 Label = 'unit test suite (test)' },
    @{ Step = 'smoke';                Label = 'ABI smoke (smoke)' },
    @{ Step = 'io-smoke';             Label = 'unified I/O smoke (io-smoke)' },
    @{ Step = 'json-smoke';           Label = 'lf_json C ABI smoke (json-smoke)' },
    @{ Step = 'network-events-smoke'; Label = 'network events smoke' },
    @{ Step = 'status-smoke';         Label = 'status queue smoke' }
)

Write-Status "================================================================"
Write-Status "  LingoFuse Zig binding - test"
Write-Status "================================================================"
Write-Status "  Project root : $Root"
Write-Status "  Optimize     : $Optimize"
Write-Status "================================================================"

# -----------------------------------------------------------------------------
# Toolchain check.
# -----------------------------------------------------------------------------
$zigCmd = Get-Command zig -ErrorAction SilentlyContinue
if ($null -eq $zigCmd) {
    Write-Always "[FATAL] 'zig' is not on PATH." 'Red'
    exit 1
}

$zigVersion = (& zig version) 2>&1
Write-Status "  zig version  : $zigVersion"
Write-Status ""

# -----------------------------------------------------------------------------
# Run every suite. A failure is recorded but does not abort the loop, so
# that a single failure does not hide the state of the remaining suites.
# -----------------------------------------------------------------------------
$results = @()
$failedCount = 0

foreach ($suite in $suites) {
    $step  = $suite.Step
    $label = $suite.Label

    Write-Status ">>> $label"

    & zig build $step "-Doptimize=$Optimize"
    $exit = $LASTEXITCODE
    if ($null -eq $exit) { $exit = 0 }

    if ($exit -eq 0) {
        Write-Status "    PASS" 'Green'
    } else {
        Write-Status "    FAIL (exit code $exit)" 'Red'
        $failedCount += 1
    }

    $status = if ($exit -eq 0) { 'PASS' } else { 'FAIL' }
    $results += [PSCustomObject]@{
        Suite  = $label
        Status = $status
        Exit   = $exit
    }
}

# -----------------------------------------------------------------------------
# Summary table.
# -----------------------------------------------------------------------------
Write-Always ""
Write-Always "================================================================"
Write-Always "  Test summary"
Write-Always "================================================================"
Write-Always ("  {0,-45} {1,-6}" -f 'Suite', 'Status')
Write-Always ("  {0,-45} {1,-6}" -f ('-' * 45), ('-' * 6))

foreach ($r in $results) {
    $color = if ($r.Status -eq 'PASS') { 'Green' } else { 'Red' }
    Write-Always ("  {0,-45} {1,-6}" -f $r.Suite, $r.Status) $color
}

Write-Always "================================================================"
if ($failedCount -eq 0) {
    Write-Always "  RESULT: ALL SUITES PASSED" 'Green'
    Write-Always "================================================================"
    exit 0
} else {
    Write-Always "  RESULT: $failedCount SUITE(S) FAILED" 'Red'
    Write-Always "================================================================"
    exit 2
}