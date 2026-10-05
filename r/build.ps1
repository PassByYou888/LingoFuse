<#
.SYNOPSIS
    Build the LingoFuse R bridge and its C++ test clients.
#>

[CmdletBinding()]
param([switch]$Rebuild)

$ErrorActionPreference = "Stop"

$RootDir    = $PSScriptRoot
$SourceDir  = Join-Path $RootDir "c_ext\src"
$TestsDir   = Join-Path $RootDir "c_ext\tests"
$LibsDir    = Join-Path $RootDir "libs"
$DllName    = "lfR_bridge.dll"
$DllPath    = Join-Path $LibsDir $DllName
$TestSvcSrc = Join-Path $TestsDir "test_service.cpp"
$TestSvcExe = Join-Path $TestsDir "test_service.exe"
$EchoCliSrc = Join-Path $TestsDir "echo_client.cpp"
$EchoCliExe = Join-Path $TestsDir "echo_client.exe"
$CrossCliSrc = Join-Path $TestsDir "cross_client.cpp"
$CrossCliExe = Join-Path $TestsDir "cross_client.exe"

function Write-Section { param([string]$T)
    Write-Host ""; Write-Host ("=" * 72) -ForegroundColor Cyan
    Write-Host $T -ForegroundColor Cyan; Write-Host ("=" * 72) -ForegroundColor Cyan
}
function Write-Step { param([string]$T)
    Write-Host ""; Write-Host (">> " + $T) -ForegroundColor Yellow
}
function Write-Ok   { param([string]$T) Write-Host ("[OK]   " + $T) -ForegroundColor Green }
function Write-Warn { param([string]$T) Write-Host ("[WARN] " + $T) -ForegroundColor Yellow }
function Write-Info { param([string]$T) Write-Host ("       " + $T) -ForegroundColor Gray }
function Write-Fail { param([string]$T) Write-Host ("[FAIL] " + $T) -ForegroundColor Red }

Write-Section "LingoFuse R Bridge - Build"

# -----------------------------------------------------------------------------
# Pre-flight
# -----------------------------------------------------------------------------
Write-Step "Pre-flight checks"

$rExe = Get-Command R.exe -ErrorAction SilentlyContinue
if (-not $rExe) {
    Write-Fail "R.exe not found on PATH."
    exit 1
}
Write-Ok ("R.exe: " + $rExe.Source)

foreach ($f in @("lf_r_shim.c", "lf_bridge.cpp", "lf_r_shim.h")) {
    if (-not (Test-Path (Join-Path $SourceDir $f))) {
        Write-Fail ("Missing source file: " + $f)
        exit 1
    }
}
Write-Ok "Bridge source files present"

# -----------------------------------------------------------------------------
# Optional clean
# -----------------------------------------------------------------------------
if ($Rebuild) {
    Write-Step "Removing previous artifacts (-Rebuild)"
    Get-ChildItem -Path $SourceDir -Include "*.o","*.obj","*.dll" -File -ErrorAction SilentlyContinue |
        ForEach-Object { Remove-Item -Force $_.FullName; Write-Info ("removed " + $_.Name) }
    foreach ($p in @($DllPath, $TestSvcExe, $EchoCliExe, $CrossCliExe)) {
        if (Test-Path $p) { Remove-Item -Force $p; Write-Info ("removed " + (Split-Path $p -Leaf)) }
    }
}

if (-not (Test-Path $LibsDir)) {
    New-Item -ItemType Directory -Path $LibsDir -Force | Out-Null
    Write-Info ("Created: " + $LibsDir)
}

# -----------------------------------------------------------------------------
# 1. Bridge DLL
# -----------------------------------------------------------------------------
Write-Step "Building lfR_bridge.dll with R CMD SHLIB"

Push-Location $SourceDir
try {
    & $rExe.Source CMD SHLIB lf_r_shim.c lf_bridge.cpp -o $DllName
    $rc = $LASTEXITCODE
} finally {
    Pop-Location
}

if ($rc -ne 0) {
    Write-Fail ("R CMD SHLIB failed (exit code " + $rc + ").")
    exit 1
}

$built = Join-Path $SourceDir $DllName
if (-not (Test-Path $built)) {
    Write-Fail ("Build reported success but " + $built + " is missing.")
    exit 1
}
Move-Item -Force $built $DllPath
Write-Ok ("Bridge: " + $DllPath)
Write-Info ("Size:   " + [math]::Round((Get-Item $DllPath).Length / 1KB, 2) + " KB")

# -----------------------------------------------------------------------------
# 2. C++ test binaries
# -----------------------------------------------------------------------------
Write-Step "Building C++ test binaries"

$gpp = Get-Command g++.exe -ErrorAction SilentlyContinue
if (-not $gpp) {
    Write-Warn "g++ not found on PATH; skipping C++ test binaries."
} else {
    # test_service.exe
    if (Test-Path $TestSvcSrc) {
        & $gpp.Source -std=c++17 -O2 -I"$SourceDir" -o $TestSvcExe $TestSvcSrc
        if ($LASTEXITCODE -ne 0) {
            Write-Warn "test_service.exe build failed (non-fatal)."
        } else {
            Write-Ok ("Test service: " + $TestSvcExe)
        }
    }

    # echo_client.exe
    if (Test-Path $EchoCliSrc) {
        & $gpp.Source -std=c++17 -O2 -I"$SourceDir" -o $EchoCliExe $EchoCliSrc
        if ($LASTEXITCODE -ne 0) {
            Write-Warn "echo_client.exe build failed (non-fatal)."
        } else {
            Write-Ok ("Echo client : " + $EchoCliExe)
        }
    }

    # cross_client.exe
    if (Test-Path $CrossCliSrc) {
        & $gpp.Source -std=c++17 -O2 -I"$SourceDir" -o $CrossCliExe $CrossCliSrc
        if ($LASTEXITCODE -ne 0) {
            Write-Warn "cross_client.exe build failed (non-fatal)."
        } else {
            Write-Ok ("Cross client: " + $CrossCliExe)
        }
    }
}

# -----------------------------------------------------------------------------
# Summary
# -----------------------------------------------------------------------------
Write-Section "Build Summary"
Write-Host ("  Bridge     : " + $DllPath)
if (Test-Path $TestSvcExe) { Write-Host ("  Test svc   : " + $TestSvcExe) }
if (Test-Path $EchoCliExe) { Write-Host ("  Echo client: " + $EchoCliExe) }
if (Test-Path $CrossCliExe) { Write-Host ("  Cross client: " + $CrossCliExe) }
Write-Host ""

Write-Host "Test scenarios:" -ForegroundColor White
Write-Host ""
Write-Host "  STEP 3a (R caller -> C++ service):" -ForegroundColor White
Write-Host "    T1:  c_ext\tests\test_service.exe D:\CoreLibrary\LingoFuse\Binary" -ForegroundColor Gray
Write-Host "    T2:  Rscript c_ext\tests\caller_test.R D:\CoreLibrary\LingoFuse\Binary" -ForegroundColor Gray
Write-Host ""
Write-Host "  STEP 3b (C++ client -> R service):" -ForegroundColor White
Write-Host "    T1:  Rscript c_ext\tests\callee_test.R D:\CoreLibrary\LingoFuse\Binary" -ForegroundColor Gray
Write-Host "    T2:  c_ext\tests\echo_client.exe D:\CoreLibrary\LingoFuse\Binary" -ForegroundColor Gray
Write-Host ""

exit 0