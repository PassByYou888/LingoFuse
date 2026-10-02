<#
.SYNOPSIS
    Build the lingofuse Rust crate and its example executables.

.DESCRIPTION
    Compiles the library and, by default, the example binaries under
    examples/ (cross_service, cross_node, cross_call). This produces
    runnable .exe files in target/<profile>/examples/.

    The script never copies the native LingoFuse library. It only
    inspects PATH and the crate root to report whether the runtime is
    discoverable; the operator is responsible for deploying the native
    library.

    This script lives in the crate root. It uses $PSScriptRoot to
    locate the crate, so it works regardless of the current directory
    from which it is invoked.

.PARAMETER Release
    Build in release mode. Default: debug.

.PARAMETER LibOnly
    Build only the library crate, skipping the examples. Use this when
    you want a fast compile check on the library itself.

.PARAMETER WithTests
    Also compile the integration tests under tests/ (without running
    them).

.PARAMETER All
    Compile every target: library, examples, tests, benches. Overrides
    -LibOnly and -WithTests.

.EXAMPLE
    .\build.ps1
    Builds the library and all examples in debug mode.

.EXAMPLE
    .\build.ps1 -Release
    Builds the library and examples in release mode.

.EXAMPLE
    .\build.ps1 -LibOnly
    Builds only the library.

.EXAMPLE
    .\build.ps1 -All
    Builds every target in debug mode.
#>

[CmdletBinding()]
param(
    [switch]$Release,
    [switch]$LibOnly,
    [switch]$WithTests,
    [switch]$All
)

$ErrorActionPreference = "Stop"

# The script lives in the crate root, so $PSScriptRoot IS the crate root.
$CrateRoot = $PSScriptRoot
Set-Location $CrateRoot

# ---------------------------------------------------------------------------
# Banner
# ---------------------------------------------------------------------------
# `$buildProfile` is used instead of `$profile`, which is a PowerShell
# automatic variable pointing at the user's profile script path.
$buildProfile = if ($Release) { "release" } else { "debug" }

$scope = if ($All) {
    "all targets"
} elseif ($LibOnly) {
    "library only"
} elseif ($WithTests) {
    "library + examples + tests"
} else {
    "library + examples"
}

Write-Host ""
Write-Host "===============================================" -ForegroundColor Cyan
Write-Host " LingoFuse Rust - Build" -ForegroundColor Cyan
Write-Host "===============================================" -ForegroundColor Cyan
Write-Host " Crate root : $CrateRoot"
Write-Host " Profile    : $buildProfile"
Write-Host " Scope      : $scope"
Write-Host ""

# ---------------------------------------------------------------------------
# Native library status (read-only; nothing is copied)
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

if ($nativeInPath) {
    Write-Host "[INFO] Native library discoverable via PATH: $nativeName" -ForegroundColor Green
} elseif ($nativeInRoot) {
    Write-Host "[INFO] Native library present in crate root: $nativeName" -ForegroundColor Green
    Write-Host "       (This script did NOT copy it; it was already there.)" -ForegroundColor DarkGray
} else {
    Write-Host "[WARN] Native library '$nativeName' is not discoverable." -ForegroundColor Yellow
    Write-Host "       Compilation will succeed; running the produced binaries" -ForegroundColor Yellow
    Write-Host "       will fail at startup until the native library is available." -ForegroundColor Yellow
    Write-Host "       Add the LingoFuse Binary/ directory to PATH, or place" -ForegroundColor Yellow
    Write-Host "       the library next to the produced executable." -ForegroundColor Yellow
}
Write-Host ""

# ---------------------------------------------------------------------------
# Build arguments
# ---------------------------------------------------------------------------
$cargoArgs = @("build")

if ($Release) { $cargoArgs += "--release" }

if ($All) {
    $cargoArgs += "--all-targets"
} elseif ($LibOnly) {
    $cargoArgs += "--lib"
} elseif ($WithTests) {
    $cargoArgs += "--examples"
    $cargoArgs += "--tests"
} else {
    $cargoArgs += "--examples"
}

# ---------------------------------------------------------------------------
# Run
# ---------------------------------------------------------------------------
Write-Host "[STEP] cargo $($cargoArgs -join ' ')" -ForegroundColor Cyan
$start = Get-Date
cargo @cargoArgs
$exitCode = $LASTEXITCODE
$elapsed = (Get-Date) - $start

Write-Host ""
if ($exitCode -ne 0) {
    Write-Host ("[FAIL] Build failed (exit code {0}) after {1:N2}s" -f $exitCode, $elapsed.TotalSeconds) -ForegroundColor Red
    exit $exitCode
}

Write-Host ("[OK]   Build succeeded in {0:N2}s" -f $elapsed.TotalSeconds) -ForegroundColor Green
Write-Host ""

# ---------------------------------------------------------------------------
# Report produced executables
# ---------------------------------------------------------------------------
$exeExt = if ($IsWindows -or $env:OS -eq "Windows_NT") { ".exe" } else { "" }
$examplesDir = Join-Path $CrateRoot ("target/{0}/examples" -f $buildProfile)

if (Test-Path $examplesDir) {
    $exes = Get-ChildItem -Path $examplesDir -File |
            Where-Object { $_.Name -like "*$exeExt" -and $_.Name -notlike "*.d" -and $_.Name -notlike "*.pdb" }

    if ($exes.Count -gt 0) {
        Write-Host "[INFO] Produced example executables:" -ForegroundColor Cyan
        foreach ($f in $exes) {
            $size = "{0:N2} MB" -f ($f.Length / 1MB)
            Write-Host ("       {0}  ({1})" -f $f.FullName, $size)
        }
        Write-Host ""
        Write-Host "       Run with:" -ForegroundColor DarkGray
        Write-Host ("       {0}\target\{1}\examples\cross_service{2}" -f $CrateRoot, $buildProfile, $exeExt) -ForegroundColor DarkGray
        Write-Host ("       {0}\target\{1}\examples\cross_node{2}"    -f $CrateRoot, $buildProfile, $exeExt) -ForegroundColor DarkGray
        Write-Host ("       {0}\target\{1}\examples\cross_call{2}"    -f $CrateRoot, $buildProfile, $exeExt) -ForegroundColor DarkGray
        Write-Host ""
        Write-Host "       Or via cargo:" -ForegroundColor DarkGray
        $cargoProfile = if ($Release) { "--release " } else { "" }
        Write-Host ("       cargo run {0}--example cross_service" -f $cargoProfile) -ForegroundColor DarkGray
        Write-Host ("       cargo run {0}--example cross_node"    -f $cargoProfile) -ForegroundColor DarkGray
        Write-Host ("       cargo run {0}--example cross_call"    -f $cargoProfile) -ForegroundColor DarkGray
    }
}

exit 0