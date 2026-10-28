#Requires -Version 5.1
[CmdletBinding()]
param(
    [switch]$SkipBridge,
    [switch]$SkipDart,
    [switch]$Force,
    [string]$LingoFuseBinDir = 'D:\CoreLibrary\LingoFuse\Binary'
)

$ErrorActionPreference = 'Stop'
$RootDir = $PSScriptRoot
$BridgeDir = Join-Path $RootDir 'bridge'

function Write-Step { param([string]$Msg) Write-Host ""; Write-Host ">>> $Msg" -ForegroundColor Cyan }
function Write-Ok { param([string]$Msg) Write-Host "[ OK ] $Msg" -ForegroundColor Green }
function Write-Fail { param([string]$Msg) Write-Host "[FAIL] $Msg" -ForegroundColor Red }
function Write-Info { param([string]$Msg) Write-Host "[info] $Msg" -ForegroundColor DarkGray }

Write-Host "============================================================"
Write-Host "  build.ps1  (LingoFuse Dart binding)"
Write-Host "  RootDir         : $RootDir"
Write-Host "  BridgeDir       : $BridgeDir"
Write-Host "  LingoFuseBinDir : $LingoFuseBinDir"
Write-Host "  PSVersion       : $($PSVersionTable.PSVersion)"
Write-Host "============================================================"

Write-Step 'Toolchain checks'

$dartCmd = Get-Command dart -ErrorAction SilentlyContinue
if (-not $dartCmd) {
    Write-Fail 'dart not found on PATH'
    exit 1
}
$dartVersion = (& dart --version 2>&1) -join ' '
Write-Ok "dart: $dartVersion"

if (-not (Test-Path (Join-Path $BridgeDir 'build.ps1'))) {
    Write-Fail "bridge/build.ps1 not found at $BridgeDir"
    exit 1
}
Write-Ok 'bridge/build.ps1 present'

if (-not (Test-Path (Join-Path $LingoFuseBinDir 'LingoFuse64.dll'))) {
    Write-Fail "LingoFuse64.dll not found at $LingoFuseBinDir"
    Write-Info 'Set -LingoFuseBinDir to the directory that contains LingoFuse64.dll'
    exit 1
}
Write-Ok 'LingoFuse64.dll present'

if (-not (Test-Path (Join-Path $LingoFuseBinDir 'z_ipc_64.dll'))) {
    Write-Fail "z_ipc_64.dll not found at $LingoFuseBinDir"
    Write-Info 'LingoFuse64.dll depends on z_ipc_64.dll and mimalloc64.dll'
    exit 1
}
Write-Ok 'z_ipc_64.dll present'

if (-not (Test-Path (Join-Path $LingoFuseBinDir 'mimalloc64.dll'))) {
    Write-Info "mimalloc64.dll not found at $LingoFuseBinDir (usually optional but recommended)"
} else {
    Write-Ok 'mimalloc64.dll present'
}

Write-Step 'Bridge interpreter check'

$bridgeBuildScript = Join-Path $BridgeDir 'build.ps1'

$currentMajor = $PSVersionTable.PSVersion.Major
$pwshCmd = Get-Command pwsh -ErrorAction SilentlyContinue

if ($currentMajor -ge 7) {
    Write-Ok "current shell is PowerShell $currentMajor (>= 7); will run bridge build in-process"
    $bridgeMode = 'InProcess'
} elseif ($pwshCmd) {
    $pwshVer = (& $pwshCmd.Source -NoProfile -Command '$PSVersionTable.PSVersion.ToString()' 2>&1) -join ' '
    Write-Ok "current shell is PowerShell $currentMajor; pwsh available ($pwshVer); will run bridge build as subprocess"
    $bridgeMode = 'PwshSubprocess'
} else {
    Write-Fail "current shell is PowerShell $currentMajor and 'pwsh' (PowerShell 7+) is not on PATH"
    Write-Info 'bridge/build.ps1 declares #Requires -Version 7.0'
    Write-Info 'Install PowerShell 7 from https://aka.ms/powershell or run this script from a pwsh shell'
    exit 1
}

Write-Step 'Build bridge DLL'

if ($SkipBridge) {
    Write-Info 'skipped (-SkipBridge)'
} else {
    Push-Location $BridgeDir
    try {
        $global:LASTEXITCODE = 0
        switch ($bridgeMode) {
            'InProcess' {
                & $bridgeBuildScript
            }
            'PwshSubprocess' {
                & $pwshCmd.Source -NoProfile -ExecutionPolicy Bypass -File $bridgeBuildScript
            }
        }
        $rc = $global:LASTEXITCODE
    } finally {
        Pop-Location
    }
    if ($rc -ne 0) {
        Write-Fail "bridge/build.ps1 failed (exit $rc)"
        exit 1
    }
    Write-Ok 'bridge/build.ps1 completed'
}

Write-Step 'Verify bridge artifacts'

$bridgeDll = Join-Path $BridgeDir 'lf_dart_bridge.dll'
$rootDll = Join-Path $RootDir 'lf_dart_bridge.dll'

if (-not (Test-Path $bridgeDll)) {
    Write-Fail "Missing $bridgeDll; bridge build did not produce the DLL"
    exit 1
}
Write-Ok "bridge DLL: $bridgeDll"

if ($Force -or -not (Test-Path $rootDll)) {
    Copy-Item -LiteralPath $bridgeDll -Destination $rootDll -Force
    Write-Ok "copied bridge DLL to $rootDll"
} else {
    $bTime = (Get-Item -LiteralPath $bridgeDll).LastWriteTime
    $rTime = (Get-Item -LiteralPath $rootDll).LastWriteTime
    if ($bTime -gt $rTime) {
        Copy-Item -LiteralPath $bridgeDll -Destination $rootDll -Force
        Write-Ok "refreshed root DLL (newer than root copy)"
    } else {
        Write-Ok "root DLL is up to date"
    }
}

Write-Step 'Resolve Dart dependencies'

if ($SkipDart) {
    Write-Info 'skipped (-SkipDart)'
} else {
    Push-Location $RootDir
    try {
        $global:LASTEXITCODE = 0
        & dart pub get
        $rc = $global:LASTEXITCODE
    } finally {
        Pop-Location
    }
    if ($rc -ne 0) {
        Write-Fail "dart pub get failed (exit $rc)"
        exit 1
    }
    Write-Ok 'dart pub get completed'
}

Write-Host ""
Write-Host "============================================================" -ForegroundColor Green
Write-Host "  BUILD OK" -ForegroundColor Green
Write-Host "============================================================" -ForegroundColor Green
Write-Info 'Next: run test.ps1'
exit 0