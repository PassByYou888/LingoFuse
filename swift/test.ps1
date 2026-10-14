# =============================================================================
#  test.ps1
# -----------------------------------------------------------------------------
#  Thin wrapper around `swift test`.
#
#  What this script does NOT do:
#    - It does not filter, rewrite, or buffer the Swift test output.
#    - It does not parse XCTest summaries.
#    - It does not print its own pass/fail summary.
#
#  What this script does:
#    1. Optionally sets the console output encoding to UTF-8.
#    2. Optionally delegates to build.ps1 for a fresh build.
#    3. Runs `swift test` and lets its output go straight to the terminal.
#    4. Returns the swift test exit code.
#
#  The exit code is the authoritative signal: 0 means all tests passed,
#  non-zero means one or more failed. The full XCTest report is on the
#  terminal.
#
#  Usage:
#      .\test.ps1
#      .\test.ps1 -Filter CAbiTests
#      .\test.ps1 -Release
#      .\test.ps1 -SkipBuild
#      .\test.ps1 -Quiet
#      .\test.ps1 -NoEncoding
#
#  Exit codes:
#      0  all tests passed
#      1  one or more tests failed, or the build failed
#      2  startup error (Swift not found, Package.swift missing, ...)
# =============================================================================

param(
    [string] $Filter = "",
    [switch] $Release,
    [switch] $SkipBuild,
    [switch] $Quiet,
    [switch] $NoEncoding
)

$ErrorActionPreference = "Stop"

# -----------------------------------------------------------------------------
#  Console output encoding (see the same block in build.ps1).
# -----------------------------------------------------------------------------

if (-not $NoEncoding) {
    try {
        [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
        $OutputEncoding           = [System.Text.Encoding]::UTF8
    } catch { }
}

# -----------------------------------------------------------------------------
#  Helpers
# -----------------------------------------------------------------------------

function Write-Section([string]$title) {
    if ($Quiet) { return }
    Write-Host ""
    Write-Host "======================================================================" -ForegroundColor Cyan
    Write-Host "  $title" -ForegroundColor Cyan
    Write-Host "======================================================================" -ForegroundColor Cyan
}

function Write-Info([string]$msg) {
    if ($Quiet) { return }
    Write-Host "  $msg"
}

function Write-Ok([string]$msg) {
    Write-Host "  [OK]   $msg" -ForegroundColor Green
}

function Write-Err([string]$msg) {
    Write-Host "  [ERR]  $msg" -ForegroundColor Red
}

# -----------------------------------------------------------------------------
#  1. Locate the project root
# -----------------------------------------------------------------------------

$ProjectDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$ManifestPath = Join-Path $ProjectDir "Package.swift"

if (-not (Test-Path $ManifestPath)) {
    Write-Host "[FATAL] Package.swift not found in $ProjectDir" -ForegroundColor Red
    exit 2
}

# -----------------------------------------------------------------------------
#  2. Verify the Swift toolchain
# -----------------------------------------------------------------------------

try {
    $null = Get-Command swift -ErrorAction Stop
} catch {
    Write-Host "[FATAL] Swift toolchain not found on PATH." -ForegroundColor Red
    Write-Host "        Install Swift 5.9 or later and ensure 'swift' is on PATH." -ForegroundColor Red
    exit 2
}

# -----------------------------------------------------------------------------
#  3. Banner
# -----------------------------------------------------------------------------

Write-Section "LingoFuse Swift Test"

$Configuration = if ($Release) { "release" } else { "debug" }
Write-Info "Project directory: $ProjectDir"
Write-Info "Configuration    : $Configuration"
if ($Filter) {
    Write-Info "Filter           : $Filter"
}

# -----------------------------------------------------------------------------
#  4. Build (unless skipped)
# -----------------------------------------------------------------------------

if (-not $SkipBuild) {
    Write-Section "Building"

    $buildScript = Join-Path $ProjectDir "build.ps1"
    if (Test-Path $buildScript) {
        $buildArgs = @()
        if ($Release)    { $buildArgs += "-Release" }
        if ($Quiet)      { $buildArgs += "-Quiet" }
        if ($NoEncoding) { $buildArgs += "-NoEncoding" }

        & $buildScript @buildArgs
        if ($LASTEXITCODE -ne 0) {
            Write-Err "build.ps1 failed with exit code $LASTEXITCODE"
            exit 1
        }
    } else {
        & swift build
        if ($LASTEXITCODE -ne 0) {
            Write-Err "swift build failed."
            exit 1
        }
    }
} else {
    Write-Info "Skipping build (-SkipBuild requested)."
}

# -----------------------------------------------------------------------------
#  5. Run swift test
#
#  Direct invocation. No pipeline, no filter, no re-print. Everything
#  the test runner prints goes straight to the terminal.
# -----------------------------------------------------------------------------

Write-Section "Running tests"

$testArgs = @("test")
if ($Release) {
    $testArgs += "-c"
    $testArgs += "release"
}
if ($Filter) {
    $testArgs += "--filter"
    $testArgs += $Filter
}

& swift @testArgs
$exitCode = $LASTEXITCODE

# -----------------------------------------------------------------------------
#  6. Report
# -----------------------------------------------------------------------------

Write-Section "Result"

if ($exitCode -eq 0) {
    Write-Ok "swift test exited with code 0 (all tests passed)."
    exit 0
} else {
    Write-Err "swift test exited with code $exitCode (one or more tests failed)."
    exit 1
}