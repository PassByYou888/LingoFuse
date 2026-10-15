# =============================================================================
#  test.ps1 - Run the complete LingoFuse Zig test suite.
# -----------------------------------------------------------------------------
#  Test suites
#  -----------
#    test                  - Zig-native unit test suite (24 tests, pure
#                            logic; no native library required).
#    smoke                 - ABI smoke test as a normal program.
#    io-smoke              - Unified I/O smoke test.
#    json-smoke            - lf_json C ABI smoke test.
#    network-events-smoke  - Network event install / query / clear.
#    status-smoke          - Status queue helpers.
#    uid-smoke             - UID value type and ABI bridging.
#    identity-smoke        - P2P identity side data.
#    options-smoke         - Typed options getter / setter pairs.
#    async-smoke           - Asynchronous call family.
#    p2p-smoke             - Process-wide P2P registration.
#    addressing-smoke      - Three addressing schemes.
#
#  Why most suites are smoke programs, not Zig unit tests
#  ------------------------------------------------------
#  The Zig test runner on Windows can hang when the native LingoFuse
#  library writes diagnostics to the console. Most suites therefore run
#  as normal executables whose output is written to a log file before
#  and after each native call. This script invokes them through
#  `zig build`, collects their exit codes, and prints a summary.
#
#  The `test` suite (tests/test_abi.zig) is the exception: it contains
#  ONLY pure-logic tests (Uid value type, AsyncResult tagged union,
#  re-export existence) and never touches the native library, so the
#  test runner is safe for it.
#
#  Serial execution
#  ----------------
#  Every smoke suite that starts the process-global simulated main
#  thread must run SERIALLY. This script enforces that by running the
#  suites one after another, in a fixed order, from lowest to highest
#  layer. Do not parallelise them.
#
#  Parameters
#  ----------
#    -Optimize   Selects the Zig optimization mode (Debug by default).
#    -Quiet      Suppresses per-step progress output. Only the final
#                summary is printed.
#    -Only       Runs only the named suite(s). Accepts a comma-separated
#                list. When omitted, every suite is run.
#
#  Exit codes
#  ----------
#    0  every selected suite passed
#    1  the Zig toolchain is not available
#    2  at least one suite failed, or -Only named an unknown suite
#
#  Example
#  -------
#    .\test.ps1
#    .\test.ps1 -Optimize ReleaseFast
#    .\test.ps1 -Quiet
#    .\test.ps1 -Only uid-smoke,options-smoke
#    .\test.ps1 -Only smoke
# =============================================================================

[CmdletBinding()]
param(
    [ValidateSet('Debug', 'ReleaseSafe', 'ReleaseFast', 'ReleaseSmall')]
    [string]$Optimize = 'Debug',

    [switch]$Quiet,

    [string[]]$Only = @()
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
# Suite table.
#
# Order matters:
#   - `test` runs first (pure logic, no native library).
#   - The smoke programs then run in layer order, from lowest (raw ABI)
#     to highest (full addressing stack).
#
# Every suite below maps one-to-one to a step registered in build.zig.
# -----------------------------------------------------------------------------
$suites = @(
    @{ Step = 'test';                 Label = 'unit test suite (pure logic)' }
    @{ Step = 'smoke';                Label = 'ABI smoke (smoke)' }
    @{ Step = 'io-smoke';             Label = 'unified I/O smoke (io-smoke)' }
    @{ Step = 'json-smoke';           Label = 'lf_json C ABI smoke (json-smoke)' }
    @{ Step = 'network-events-smoke'; Label = 'network events smoke' }
    @{ Step = 'status-smoke';         Label = 'status queue smoke' }
    @{ Step = 'uid-smoke';            Label = 'UID value type smoke' }
    @{ Step = 'identity-smoke';       Label = 'P2P identity side-data smoke' }
    @{ Step = 'options-smoke';        Label = 'typed options smoke' }
    @{ Step = 'async-smoke';          Label = 'async call family smoke' }
    @{ Step = 'p2p-smoke';            Label = 'process-wide P2P registration smoke' }
    @{ Step = 'addressing-smoke';     Label = 'three addressing schemes smoke' }
)

# -----------------------------------------------------------------------------
# Validate -Only (if provided).
# -----------------------------------------------------------------------------
$knownSteps = $suites | ForEach-Object { $_.Step }

if ($Only.Count -gt 0) {
    $unknown = @()
    foreach ($name in $Only) {
        $trimmed = $name.Trim()
        if ($trimmed.Length -gt 0 -and $knownSteps -notcontains $trimmed) {
            $unknown += $trimmed
        }
    }
    if ($unknown.Count -gt 0) {
        Write-Always "[FATAL] -Only named unknown suite(s): $($unknown -join ', ')" 'Red'
        Write-Always "        Known suites: $($knownSteps -join ', ')" 'Red'
        exit 2
    }
}

# -----------------------------------------------------------------------------
# Banner.
# -----------------------------------------------------------------------------
Write-Status "================================================================"
Write-Status "  LingoFuse Zig binding - test"
Write-Status "================================================================"
Write-Status "  Project root : $Root"
Write-Status "  Optimize     : $Optimize"
if ($Only.Count -gt 0) {
    Write-Status "  Only         : $($Only -join ', ')"
} else {
    Write-Status "  Only         : (all suites)"
}
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
# Run every selected suite. A failure is recorded but does not abort the
# loop, so that a single failure does not hide the state of the remaining
# suites.
# -----------------------------------------------------------------------------
$results = @()
$failedCount = 0
$skippedCount = 0

foreach ($suite in $suites) {
    $step  = $suite.Step
    $label = $suite.Label

    if ($Only.Count -gt 0 -and ($Only -notcontains $step)) {
        $skippedCount += 1
        continue
    }

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

if ($skippedCount -gt 0) {
    Write-Always ("  ({0} suite(s) skipped by -Only)" -f $skippedCount) 'DarkGray'
}

Write-Always "================================================================"
if ($failedCount -eq 0) {
    Write-Always "  RESULT: ALL SUITES PASSED" 'Green'
    Write-Always "================================================================"
    exit 0
} else {
    Write-Always ("  RESULT: {0} SUITE(S) FAILED" -f $failedCount) 'Red'
    Write-Always "================================================================"
    exit 2
}