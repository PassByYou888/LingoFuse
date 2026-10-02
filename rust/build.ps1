<#
.SYNOPSIS
    Build the lingofuse Rust crate.

.DESCRIPTION
    Compiles the library and, optionally, the tests. Supports both debug
    and release profiles. Reports the native library status so the
    operator knows whether the build target can actually run.

    This script lives in the crate root. It uses $PSScriptRoot to
    locate the crate, so it works regardless of the current directory
    from which it is invoked.

.PARAMETER Release
    Build in release mode. Default: debug.

.PARAMETER Tests
    Also compile the integration tests without running them.

.PARAMETER Examples
    Also compile any examples found in examples/.

.EXAMPLE
    .\build.ps1
    Builds the library in debug mode.

.EXAMPLE
    .\build.ps1 -Release -Tests
    Builds the library and tests in release mode.
#>

[CmdletBinding()]
param(
    [switch]$Release,
    [switch]$Tests,
    [switch]$Examples
)

$ErrorActionPreference = "Stop"

# The script lives in the crate root, so $PSScriptRoot IS the crate root.
$CrateRoot = $PSScriptRoot
Set-Location $CrateRoot

# ---------------------------------------------------------------------------
# Banner
# ---------------------------------------------------------------------------
Write-Host ""
Write-Host "===============================================" -ForegroundColor Cyan
Write-Host " LingoFuse Rust - Build" -ForegroundColor Cyan
Write-Host "===============================================" -ForegroundColor Cyan
Write-Host " Crate root : $CrateRoot"
$profile = if ($Release) { "release" } else { "debug" }
Write-Host " Profile    : $profile"
Write-Host " Tests      : $(if ($Tests) { 'yes' } else { 'no' })"
Write-Host " Examples   : $(if ($Examples) { 'yes' } else { 'no' })"
Write-Host ""

# ---------------------------------------------------------------------------
# Native library status
# ---------------------------------------------------------------------------
$nativeName = if ($IsWindows -or $env:OS -eq "Windows_NT") {
    if ([IntPtr]::Size -eq 8) { "LingoFuse64.dll" } else { "LingoFuse32.dll" }
} elseif ($IsMacOS) {
    "liblingofuse.dylib"
} else {
    "liblingofuse.so"
}

$nativeInRoot = Test-Path (Join-Path $CrateRoot $nativeName)
$nativeInPath = $null -ne (Get-Command $nativeName -ErrorAction SilentlyContinue)

if ($nativeInRoot) {
    Write-Host "[INFO] Native library found in crate root: $nativeName" -ForegroundColor Green
} elseif ($nativeInPath) {
    Write-Host "[INFO] Native library found on system loader path: $nativeName" -ForegroundColor Green
} else {
    Write-Host "[WARN] Native library '$nativeName' not found." -ForegroundColor Yellow
    Write-Host "       The build will still succeed, but runtime tests will be skipped." -ForegroundColor Yellow
    Write-Host "       Place it in the crate root or add its directory to PATH." -ForegroundColor Yellow
}
Write-Host ""

# ---------------------------------------------------------------------------
# Build arguments
# ---------------------------------------------------------------------------
$cargoArgs = @("build")
if ($Release)  { $cargoArgs += "--release" }
if ($Tests)    { $cargoArgs += "--tests" }
if ($Examples) { $cargoArgs += "--examples" }

# ---------------------------------------------------------------------------
# Run
# ---------------------------------------------------------------------------
Write-Host "[STEP] cargo $($cargoArgs -join ' ')" -ForegroundColor Cyan
$start = Get-Date
cargo @cargoArgs
$exitCode = $LASTEXITCODE
$elapsed = (Get-Date) - $start

Write-Host ""
if ($exitCode -eq 0) {
    Write-Host ("[OK]   Build succeeded in {0:N2}s" -f $elapsed.TotalSeconds) -ForegroundColor Green
} else {
    Write-Host ("[FAIL] Build failed (exit code {0}) after {1:N2}s" -f $exitCode, $elapsed.TotalSeconds) -ForegroundColor Red
}

exit $exitCode