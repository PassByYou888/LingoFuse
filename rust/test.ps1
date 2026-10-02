<#
.SYNOPSIS
    Run the lingofuse Rust test suite.

.DESCRIPTION
    Runs up to four test layers:

      1. unit    - Unit tests (parallel-safe).
      2. ignored - Ignored unit tests (mutate process-global native
                   state; serial).
      3. abi     - ABI smoke tests (tests/abi_smoke.rs).
      4. e2e     - End-to-end framework tests (tests/framework_e2e.rs;
                   serial).

    The script never copies the native LingoFuse library. It checks
    whether the library is discoverable through PATH (or sitting in
    the crate root), and warns if it is not. A missing library makes
    every integration test print [SKIP] and return early; the unit
    tests that do not touch native code still run.

    Pass -RequireNative to turn a missing native library into a hard
    failure instead of a warning.

    This script lives in the crate root. It uses $PSScriptRoot to
    locate the crate.

.PARAMETER Layer
    Which layer(s) to run. Accepted values: all (default), unit,
    ignored, abi, e2e. Comma-separated for multiple, e.g.
    -Layer unit,abi.

.PARAMETER RequireNative
    Fail if the native library is not discoverable. Default: warn.

.PARAMETER NoCapture
    Pass --nocapture to the test harness. Useful for seeing [SKIP]
    lines from integration tests.

.EXAMPLE
    .\test.ps1
    Runs every layer.

.EXAMPLE
    .\test.ps1 -Layer unit,abi
    Runs only the unit and ABI smoke layers.

.EXAMPLE
    .\test.ps1 -RequireNative -NoCapture
    Runs everything, fails fast if the native library is missing, and
    prints the [SKIP] lines.
#>

[CmdletBinding()]
param(
    [string[]]$Layer = @("all"),
    [switch]$RequireNative,
    [switch]$NoCapture
)

$ErrorActionPreference = "Stop"

$CrateRoot = $PSScriptRoot
Set-Location $CrateRoot

# ---------------------------------------------------------------------------
# Expand -Layer
# ---------------------------------------------------------------------------
$layerSet = New-Object System.Collections.Generic.HashSet[string]
foreach ($entry in $Layer) {
    foreach ($piece in $entry.Split(",")) {
        $trimmed = $piece.Trim().ToLowerInvariant()
        if ($trimmed -eq "all") {
            [void]$layerSet.Add("unit")
            [void]$layerSet.Add("ignored")
            [void]$layerSet.Add("abi")
            [void]$layerSet.Add("e2e")
        } else {
            [void]$layerSet.Add($trimmed)
        }
    }
}

$validLayers = @("unit", "ignored", "abi", "e2e")
foreach ($l in $layerSet) {
    if ($validLayers -notcontains $l) {
        Write-Host "[FAIL] Unknown layer '$l'. Valid: $($validLayers -join ', ')" -ForegroundColor Red
        exit 2
    }
}

# ---------------------------------------------------------------------------
# Banner
# ---------------------------------------------------------------------------
Write-Host ""
Write-Host "===============================================" -ForegroundColor Cyan
Write-Host " LingoFuse Rust - Test" -ForegroundColor Cyan
Write-Host "===============================================" -ForegroundColor Cyan
Write-Host " Crate root    : $CrateRoot"
Write-Host " Layers        : $(($layerSet | Sort-Object) -join ', ')"
Write-Host " RequireNative : $RequireNative"
Write-Host " NoCapture     : $NoCapture"
Write-Host ""

# ---------------------------------------------------------------------------
# Native library presence check (read-only; nothing is copied)
# ---------------------------------------------------------------------------
$nativeName = if ($IsWindows -or $env:OS -eq "Windows_NT") {
    if ([IntPtr]::Size -eq 8) { "LingoFuse64.dll" } else { "LingoFuse32.dll" }
} elseif ($IsMacOS) {
    "liblingofuse.dylib"
} else {
    "liblingofuse.so"
}

$nativeInPath = $null -ne (Get-Command $nativeName -ErrorAction SilentlyContinue)
$nativeInRoot = Test-Path (Join-Path $CrateRoot $nativeName)
$haveNative = $nativeInPath -or $nativeInRoot

if ($haveNative) {
    $location = if ($nativeInPath) { "PATH" } else { "crate root" }
    Write-Host "[INFO] Native library discoverable via $location : $nativeName" -ForegroundColor Green
} else {
    if ($RequireNative) {
        Write-Host "[FAIL] Native library '$nativeName' not found (required)." -ForegroundColor Red
        Write-Host "       Add the LingoFuse Binary/ directory to PATH, or place" -ForegroundColor Red
        Write-Host "       the library in the crate root." -ForegroundColor Red
        Write-Host "       (This script does NOT copy the library for you.)" -ForegroundColor DarkGray
        exit 1
    }
    Write-Host "[WARN] Native library '$nativeName' not found." -ForegroundColor Yellow
    Write-Host "       Integration tests will print [SKIP] and return early." -ForegroundColor Yellow
    Write-Host "       Use -NoCapture to see the [SKIP] lines." -ForegroundColor Yellow
    Write-Host "       (This script does NOT copy the library for you.)" -ForegroundColor DarkGray
}
Write-Host ""

# ---------------------------------------------------------------------------
# Test harness arguments
# ---------------------------------------------------------------------------
$harnessArgs = @()
if ($NoCapture) { $harnessArgs += "--nocapture" }

# Layer definitions. Order matters: unit first, ignored last among unit
# layers because the ignored set mutates native global state.
$layers = [ordered]@{
    unit    = @{
        Label = "Unit tests (parallel-safe)"
        Args  = @("test", "--lib")
    }
    ignored = @{
        Label = "Ignored unit tests (serial; mutates native global state)"
        Args  = @("test", "--lib", "--", "--ignored", "--test-threads=1")
    }
    abi     = @{
        Label = "ABI smoke tests (tests/abi_smoke.rs)"
        Args  = @("test", "--test", "abi_smoke")
    }
    e2e     = @{
        Label = "End-to-end framework tests (tests/framework_e2e.rs; serial)"
        Args  = @("test", "--test", "framework_e2e", "--", "--ignored", "--test-threads=1")
    }
}

# ---------------------------------------------------------------------------
# Run selected layers
# ---------------------------------------------------------------------------
$totalFailures = 0
$totalDuration = [TimeSpan]::Zero

foreach ($name in $layers.Keys) {
    if (-not $layerSet.Contains($name)) { continue }

    $meta = $layers[$name]
    $cargoArgs = $meta.Args
    if ($harnessArgs.Count -gt 0) {
        $cargoArgs = $cargoArgs + $harnessArgs
    }

    Write-Host "-----------------------------------------------" -ForegroundColor DarkCyan
    Write-Host " [LAYER] $($meta.Label)" -ForegroundColor Cyan
    Write-Host "         cargo $($cargoArgs -join ' ')" -ForegroundColor DarkGray
    Write-Host "-----------------------------------------------" -ForegroundColor DarkCyan

    $start = Get-Date
    cargo @cargoArgs
    $exit = $LASTEXITCODE
    $elapsed = (Get-Date) - $start
    $totalDuration += $elapsed

    if ($exit -eq 0) {
        Write-Host ("[OK]   Layer '$name' passed in {0:N2}s" -f $elapsed.TotalSeconds) -ForegroundColor Green
    } else {
        Write-Host ("[FAIL] Layer '$name' failed (exit {0}) after {1:N2}s" -f $exit, $elapsed.TotalSeconds) -ForegroundColor Red
        $totalFailures += 1
    }
    Write-Host ""
}

# ---------------------------------------------------------------------------
# Report
# ---------------------------------------------------------------------------
Write-Host "===============================================" -ForegroundColor Cyan
if ($totalFailures -eq 0) {
    Write-Host (" All selected layers passed in {0:N2}s" -f $totalDuration.TotalSeconds) -ForegroundColor Green
    Write-Host "===============================================" -ForegroundColor Cyan
    exit 0
} else {
    Write-Host (" {0} layer(s) failed after {1:N2}s" -f $totalFailures, $totalDuration.TotalSeconds) -ForegroundColor Red
    Write-Host "===============================================" -ForegroundColor Cyan
    exit 1
}