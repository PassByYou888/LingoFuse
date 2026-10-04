<#
.SYNOPSIS
    Run the LingoFuse Fortran bridge test executables.

.DESCRIPTION
    Builds first (through build.ps1), then runs one or more test
    executables. Reports a combined pass/fail at the end.

    Three test suites are available:
        test_lf_fortran_c.exe    the C ABI test
        test_lf_fortran_f.exe    the Fortran binding test
        test_lf_json_f.exe       the Fortran JSON test

    Native process output is forwarded to the console via `| Out-Host`
    so it is not captured into the enclosing scope.

.PARAMETER SkipBuild
    Do not build. Just run whatever executables are already present.

.PARAMETER C
    Run only the C test.

.PARAMETER F
    Run only the Fortran binding test.

.PARAMETER J
    Run only the Fortran JSON test.

.EXAMPLE
    .\test.ps1
    Build and run all three tests.

.EXAMPLE
    .\test.ps1 -J -SkipBuild
    Run only the JSON test, no rebuild.
#>

[CmdletBinding()]
param(
    [switch]$SkipBuild,
    [switch]$C,
    [switch]$F,
    [switch]$J
)

$ErrorActionPreference = 'Continue'

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$ExtDir    = Join-Path $ScriptDir 'c_ext'

if (-not (Test-Path -LiteralPath $ExtDir)) {
    Write-Host "[FATAL] c_ext directory not found: $ExtDir" -ForegroundColor Red
    exit 2
}

# Default: run all three tests when no specific suite is requested.
$runC = $C
$runF = $F
$runJ = $J
if (-not $C -and -not $F -and -not $J) {
    $runC = $true
    $runF = $true
    $runJ = $true
}

# ---------------------------------------------------------------------------
# Banner
# ---------------------------------------------------------------------------

Write-Host ''
Write-Host '======================================================================' -ForegroundColor Cyan
Write-Host '  LingoFuse Fortran bridge - test' -ForegroundColor Cyan
Write-Host '======================================================================' -ForegroundColor Cyan
Write-Host ("  Build dir  : {0}" -f $ExtDir)
Write-Host ("  Run C test : {0}" -f $runC)
Write-Host ("  Run F test : {0}" -f $runF)
Write-Host ("  Run J test : {0}" -f $runJ)
Write-Host ''

# ---------------------------------------------------------------------------
# Optional build step
# ---------------------------------------------------------------------------

if (-not $SkipBuild) {
    Write-Host '--- Build ---' -ForegroundColor Yellow
    Write-Host ''

    $buildScript = Join-Path $ScriptDir 'build.ps1'
    if (-not (Test-Path -LiteralPath $buildScript)) {
        Write-Host ("[FATAL] build.ps1 not found at: {0}" -f $buildScript) -ForegroundColor Red
        exit 3
    }

    & $buildScript -Target c_ext
    $buildRc = $LASTEXITCODE

    Write-Host ''

    if ($buildRc -ne 0) {
        Write-Host ("[ERROR] Build failed (exit {0}); tests will not run." -f $buildRc) -ForegroundColor Red
        exit $buildRc
    }
}

# ---------------------------------------------------------------------------
# Run tests
# ---------------------------------------------------------------------------

$exitCode = 0

if ($runC) {
    $exePath = Join-Path $ExtDir 'test_lf_fortran_c.exe'
    Write-Host '--- Run: C test ---' -ForegroundColor Yellow
    if (-not (Test-Path -LiteralPath $exePath)) {
        Write-Host ("[SKIP] executable not found: {0}" -f $exePath) -ForegroundColor Yellow
    }
    else {
        Push-Location -LiteralPath $ExtDir
        try {
            & $exePath | Out-Host
            if ($LASTEXITCODE -ne 0) { $exitCode = 1 }
        }
        finally { Pop-Location }
    }
    Write-Host ''
}

if ($runF) {
    $exePath = Join-Path $ExtDir 'test_lf_fortran_f.exe'
    Write-Host '--- Run: Fortran binding test ---' -ForegroundColor Yellow
    if (-not (Test-Path -LiteralPath $exePath)) {
        Write-Host ("[SKIP] executable not found: {0}" -f $exePath) -ForegroundColor Yellow
    }
    else {
        Push-Location -LiteralPath $ExtDir
        try {
            & $exePath | Out-Host
            if ($LASTEXITCODE -ne 0) { $exitCode = 1 }
        }
        finally { Pop-Location }
    }
    Write-Host ''
}

if ($runJ) {
    $exePath = Join-Path $ExtDir 'test_lf_json_f.exe'
    Write-Host '--- Run: Fortran JSON test ---' -ForegroundColor Yellow
    if (-not (Test-Path -LiteralPath $exePath)) {
        Write-Host ("[SKIP] executable not found: {0}" -f $exePath) -ForegroundColor Yellow
    }
    else {
        Push-Location -LiteralPath $ExtDir
        try {
            & $exePath | Out-Host
            if ($LASTEXITCODE -ne 0) { $exitCode = 1 }
        }
        finally { Pop-Location }
    }
    Write-Host ''
}

# ---------------------------------------------------------------------------
# Final verdict
# ---------------------------------------------------------------------------

if ($exitCode -eq 0) {
    Write-Host '[OK] All requested tests passed.' -ForegroundColor Green
}
else {
    Write-Host '[ERROR] One or more tests failed.' -ForegroundColor Red
}

Write-Host ''
exit $exitCode