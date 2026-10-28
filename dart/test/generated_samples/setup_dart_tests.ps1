#Requires -Version 5.1
[CmdletBinding()]
param(
    [string]$GenDir = "",
    [string]$BridgeDll = "",
    [string]$LingoFuseBinDir = "",
    [int]$ReadyTimeoutSec = 30,
    [switch]$KeepAlive
)

$ErrorActionPreference = 'Stop'

function Write-Step { param([string]$Msg) Write-Host ""; Write-Host ">>> $Msg" -ForegroundColor Cyan }
function Write-Ok   { param([string]$Msg) Write-Host "[OK]   $Msg" -ForegroundColor Green }
function Write-Fail { param([string]$Msg) Write-Host "[FAIL] $Msg" -ForegroundColor Red }
function Write-Info { param([string]$Msg) Write-Host "[info] $Msg" -ForegroundColor DarkGray }

function Find-File-Upward {
    param(
        [Parameter(Mandatory=$true)][string]$StartDir,
        [Parameter(Mandatory=$true)][string]$FileName,
        [int]$MaxLevels = 6
    )
    $cur = (Resolve-Path -LiteralPath $StartDir).Path
    for ($i = 0; $i -lt $MaxLevels; $i++) {
        $candidate = Join-Path $cur $FileName
        if (Test-Path -LiteralPath $candidate) {
            return (Resolve-Path -LiteralPath $candidate).Path
        }
        $parent = Split-Path -Parent $cur
        if (-not $parent -or $parent -eq $cur) { break }
        $cur = $parent
    }
    return $null
}

if (-not $GenDir) { $GenDir = $PSScriptRoot }
$GenDir = (Resolve-Path -LiteralPath $GenDir).Path

$svcScript = Join-Path $GenDir 'simplecalc_abi_service_test.dart'
$callScript = Join-Path $GenDir 'simplecalc_abi_call_test.dart'
$svcLog = Join-Path $GenDir 'simplecalc_service.log'
$svcStdout = Join-Path $GenDir 'simplecalc_service_stdout.log'
$svcStderr = Join-Path $GenDir 'simplecalc_service_stderr.log'
$sentinel = Join-Path $GenDir 'simplecalc_service.exit'

Write-Host "============================================================"
Write-Host "  setup_dart_tests.ps1"
Write-Host "  GenDir  : $GenDir"
Write-Host "  SvcLog  : $svcLog"
Write-Host "  Sentinel: $sentinel"
Write-Host "============================================================"

Write-Step 'Preconditions'
$dartCmd = Get-Command dart -ErrorAction SilentlyContinue
if (-not $dartCmd) {
    Write-Fail 'dart not found on PATH'
    exit 1
}
Write-Ok ('dart: ' + ((& dart --version 2>&1) -join ' '))

if (-not (Test-Path -LiteralPath $svcScript)) {
    Write-Fail "missing: $svcScript"
    exit 1
}
if (-not (Test-Path -LiteralPath $callScript)) {
    Write-Fail "missing: $callScript"
    exit 1
}

Write-Step 'Locating native DLLs'

if (-not $BridgeDll) {
    if ($env:LINGOFUSE_BRIDGE_DLL -and (Test-Path -LiteralPath $env:LINGOFUSE_BRIDGE_DLL)) {
        $BridgeDll = $env:LINGOFUSE_BRIDGE_DLL
    } else {
        $BridgeDll = Find-File-Upward -StartDir $GenDir -FileName 'lf_dart_bridge.dll'
    }
}
if (-not $BridgeDll -or -not (Test-Path -LiteralPath $BridgeDll)) {
    Write-Fail 'lf_dart_bridge.dll not found. Build it first (dart\bridge\build.ps1) or pass -BridgeDll.'
    Write-Info 'Searched: LINGOFUSE_BRIDGE_DLL, CWD, and up to 6 parent directories'
    exit 1
}
$BridgeDll = (Resolve-Path -LiteralPath $BridgeDll).Path
Write-Ok "bridge DLL: $BridgeDll"

if (-not $LingoFuseBinDir) {
    if ($env:LINGOFUSE_BIN_DIR -and (Test-Path -LiteralPath $env:LINGOFUSE_BIN_DIR)) {
        $LingoFuseBinDir = $env:LINGOFUSE_BIN_DIR
    } elseif (Test-Path -LiteralPath 'D:\CoreLibrary\LingoFuse\Binary') {
        $LingoFuseBinDir = 'D:\CoreLibrary\LingoFuse\Binary'
    } else {
        $found = Find-File-Upward -StartDir $GenDir -FileName 'LingoFuse64.dll'
        if ($found) { $LingoFuseBinDir = Split-Path -Parent $found }
    }
}
if (-not $LingoFuseBinDir -or -not (Test-Path -LiteralPath $LingoFuseBinDir)) {
    Write-Fail 'LingoFuse binary directory not found. Pass -LingoFuseBinDir or set LINGOFUSE_BIN_DIR.'
    exit 1
}
$LingoFuseBinDir = (Resolve-Path -LiteralPath $LingoFuseBinDir).Path
Write-Ok "LingoFuse bin: $LingoFuseBinDir"

$lf64 = Join-Path $LingoFuseBinDir 'LingoFuse64.dll'
if (-not (Test-Path -LiteralPath $lf64)) {
    Write-Fail "LingoFuse64.dll not found in $LingoFuseBinDir"
    exit 1
}
Write-Ok "LingoFuse64.dll: $lf64"
foreach ($dep in @('z_ipc_64.dll', 'mimalloc64.dll')) {
    $p = Join-Path $LingoFuseBinDir $dep
    if (Test-Path -LiteralPath $p) {
        Write-Ok "  dependency: $dep"
    } else {
        Write-Info "  dependency missing (may still work): $dep"
    }
}

Write-Step 'Configuring child process environment'

$env:LINGOFUSE_BRIDGE_DLL = $BridgeDll
Write-Info "LINGOFUSE_BRIDGE_DLL = $env:LINGOFUSE_BRIDGE_DLL"

$pathParts = $env:PATH -split ';' | Where-Object { $_ -ne '' }
if (-not ($pathParts -contains $LingoFuseBinDir)) {
    $env:PATH = $LingoFuseBinDir + ';' + $env:PATH
    Write-Info "PATH prepended with: $LingoFuseBinDir"
} else {
    Write-Info "PATH already contains: $LingoFuseBinDir"
}

foreach ($f in @($svcLog, $svcStdout, $svcStderr, $sentinel)) {
    if (Test-Path -LiteralPath $f) {
        Remove-Item -LiteralPath $f -Force -ErrorAction SilentlyContinue
    }
}

Write-Step 'Starting service test (background)'
$svcProc = Start-Process -FilePath 'dart' `
    -ArgumentList @('run', $svcScript, $svcLog, $sentinel) `
    -WorkingDirectory $GenDir `
    -RedirectStandardOutput $svcStdout `
    -RedirectStandardError $svcStderr `
    -PassThru -NoNewWindow
Write-Info ('service pid = ' + $svcProc.Id)

Write-Step 'Waiting for [READY] marker'
$deadline = (Get-Date).AddSeconds($ReadyTimeoutSec)
$ready = $false
$earlyExit = $false
while ((Get-Date) -lt $deadline) {
    Start-Sleep -Milliseconds 200
    if (Test-Path -LiteralPath $svcLog) {
        $content = Get-Content -LiteralPath $svcLog -Raw -ErrorAction SilentlyContinue
        if ($content -and ($content -match '\[READY\]')) {
            $ready = $true
            break
        }
    }
    $svcProc.Refresh()
    if ($svcProc.HasExited) {
        Start-Sleep -Milliseconds 100
        $svcProc.Refresh()
        $codeText = ''
        try { $codeText = $svcProc.ExitCode.ToString() } catch {}
        Write-Fail ('service exited prematurely (exit=' + $codeText + ')')
        $earlyExit = $true
        break
    }
}

if (-not $ready) {
    Write-Fail 'service did not become ready'
    if (-not $svcProc.HasExited) {
        try { $svcProc.Kill() } catch {}
    }
    Write-Host '--- service log ---'
    if (Test-Path -LiteralPath $svcLog) {
        Get-Content -LiteralPath $svcLog | ForEach-Object { Write-Host $_ }
    }
    Write-Host '--- service stdout ---'
    if (Test-Path -LiteralPath $svcStdout) {
        Get-Content -LiteralPath $svcStdout | ForEach-Object { Write-Host $_ }
    }
    Write-Host '--- service stderr ---'
    if (Test-Path -LiteralPath $svcStderr) {
        Get-Content -LiteralPath $svcStderr | ForEach-Object { Write-Host $_ }
    }
    exit 1
}
Write-Ok 'service is ready'

Write-Step 'Running call test (foreground)'
$callExit = 0
try {
    Push-Location $GenDir
    & dart run $callScript
    $callExit = $LASTEXITCODE
} finally {
    Pop-Location
}

Write-Step 'Stopping service'
if (-not $svcProc.HasExited) {
    if ($KeepAlive) {
        Write-Info 'KeepAlive specified; service left running'
    } else {
        'shutdown' | Out-File -LiteralPath $sentinel -Encoding utf8 -Force
        if (-not $svcProc.WaitForExit(5000)) {
            Write-Info 'service did not exit within 5s; killing'
            try { $svcProc.Kill() } catch {}
        }
        if (Test-Path -LiteralPath $sentinel) {
            Remove-Item -LiteralPath $sentinel -Force -ErrorAction SilentlyContinue
        }
    }
}

Write-Host ""
Write-Host "============================================================"
if ($callExit -eq 0) {
    Write-Host "  ALL DART TESTS PASSED" -ForegroundColor Green
} else {
    Write-Host ("  DART TESTS FAILED (call exit=" + $callExit + ")") -ForegroundColor Red
}
Write-Host "============================================================"
exit $callExit