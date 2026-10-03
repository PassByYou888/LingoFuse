# =============================================================================
#  test.ps1
# -----------------------------------------------------------------------------
#  One-shot test driver for the LingoFuse Swift binding.
#
#  Steps:
#    1. Locate the project root.
#    2. Verify that the Swift toolchain is installed.
#    3. Build the project (delegates to build.ps1 unless -SkipBuild).
#    4. Run `swift test` with optional filtering.
#    5. Parse the XCTest summary and print a compact report.
#
#  Usage:
#      .\test.ps1
#      .\test.ps1 -Filter CAbiTests
#      .\test.ps1 -Release
#      .\test.ps1 -SkipBuild -Quiet
#
#  Exit codes:
#      0  all tests passed
#      1  one or more tests failed
#      2  startup error (Swift not found, Package.swift missing, ...)
# =============================================================================

param(
    [string] $Filter = "",
    [switch] $Release,
    [switch] $SkipBuild,
    [switch] $Quiet
)

$ErrorActionPreference = "Stop"

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

function Write-Warn([string]$msg) {
    Write-Host "  [WARN] $msg" -ForegroundColor Yellow
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
        if ($Release) { $buildArgs += "-Release" }
        if ($Quiet)   { $buildArgs += "-Quiet" }

        & $buildScript @buildArgs
        if ($LASTEXITCODE -ne 0) {
            Write-Err "build.ps1 failed with exit code $LASTEXITCODE"
            exit 1
        }
    } else {
        Write-Warn "build.ps1 not found; falling back to swift build."
        & swift build
        if ($LASTEXITCODE -ne 0) {
            Write-Err "swift build failed."
            exit 1
        }
    }
    Write-Ok "Build complete."
} else {
    Write-Info "Skipping build (-SkipBuild requested)."
}

# -----------------------------------------------------------------------------
#  5. Run swift test
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

$capturedLines = New-Object System.Collections.ArrayList

try {
    & swift @testArgs 2>&1 | ForEach-Object {
        [void]$capturedLines.Add($_)
        if (-not $Quiet) { Write-Host $_ }
    }
    $exitCode = $LASTEXITCODE
} catch {
    Write-Err "swift test threw an exception: $_"
    exit 1
}

# -----------------------------------------------------------------------------
#  6. Parse the XCTest summary from the captured output
# -----------------------------------------------------------------------------
#
# XCTest prints one "Executed N tests, with M failures" line per suite,
# ending with an "All tests" summary. We keep the last one, which is the
# process-wide total.

$totalTests    = 0
$totalFailures = 0
$summaryLine   = ""

foreach ($line in $capturedLines) {
    $s = [string]$line
    if ($s -match "Executed\s+(\d+)\s+tests?,\s+with\s+(\d+)\s+failures?") {
        $totalTests    = [int]$Matches[1]
        $totalFailures = [int]$Matches[2]
        $summaryLine   = $s
    }
}

# -----------------------------------------------------------------------------
#  7. Report
# -----------------------------------------------------------------------------

Write-Section "Summary"

Write-Info "Configuration : $Configuration"
if ($Filter) {
    Write-Info "Filter        : $Filter"
}
if ($summaryLine) {
    Write-Info "Last XCTest   : $summaryLine"
}
Write-Info "Tests         : $totalTests"
Write-Info "Failures      : $totalFailures"

if ($totalTests -eq 0) {
    Write-Warn "No test summary was found in the output."
    Write-Warn "The filter may have matched nothing, or the output format changed."
    if ($exitCode -eq 0) {
        Write-Ok "swift test returned exit code 0."
        exit 0
    }
    Write-Err "swift test returned exit code $exitCode."
    exit 1
}

if ($totalFailures -gt 0) {
    Write-Err "$totalFailures test(s) failed out of $totalTests."
    exit 1
}

Write-Ok "All $totalTests tests passed."
exit 0