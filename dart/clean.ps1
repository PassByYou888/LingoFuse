#Requires -Version 5.1
[CmdletBinding()]
param(
    [switch]$All,
    [switch]$BridgeOnly
)

$ErrorActionPreference = 'Continue'
$RootDir = $PSScriptRoot
$BridgeDir = Join-Path $RootDir 'bridge'

function Write-Step { param([string]$Msg) Write-Host ""; Write-Host ">>> $Msg" -ForegroundColor Cyan }
function Write-Ok { param([string]$Msg) Write-Host "[ ok ] $Msg" -ForegroundColor Green }
function Write-Info { param([string]$Msg) Write-Host "[info] $Msg" -ForegroundColor DarkGray }

Write-Host "============================================================"
Write-Host "  clean.ps1  (LingoFuse Dart binding)"
Write-Host "  RootDir   : $RootDir"
Write-Host "  BridgeDir : $BridgeDir"
Write-Host "  Mode      : $(if ($All) { 'ALL (including pubspec.lock)' } elseif ($BridgeOnly) { 'BRIDGE-ONLY' } else { 'DEFAULT' })"
Write-Host "============================================================"

function Remove-PathSafe {
    param([string]$Path, [switch]$Recurse)
    if (Test-Path -LiteralPath $Path) {
        try {
            if ($Recurse) {
                Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction Stop
            } else {
                Remove-Item -LiteralPath $Path -Force -ErrorAction Stop
            }
            Write-Info "removed: $Path"
        } catch {
            Write-Host "[warn] could not remove ${Path}: $_" -ForegroundColor Yellow
        }
    }
}

Write-Step 'Bridge build artifacts'

Remove-PathSafe (Join-Path $BridgeDir 'obj') -Recurse
Remove-PathSafe (Join-Path $BridgeDir 'lf_dart_bridge.dll')
Remove-PathSafe (Join-Path $BridgeDir 'lf_dart_bridge.exp')
Remove-PathSafe (Join-Path $BridgeDir 'lf_dart_bridge.lib')
Remove-PathSafe (Join-Path $RootDir 'lf_dart_bridge.dll')

if ($BridgeOnly) {
    Write-Host ""
    Write-Host "============================================================" -ForegroundColor Green
    Write-Host "  CLEAN OK (bridge only)" -ForegroundColor Green
    Write-Host "============================================================" -ForegroundColor Green
    exit 0
}

Write-Step 'Dart analysis cache'

Remove-PathSafe (Join-Path $RootDir '.dart_tool') -Recurse
Remove-PathSafe (Join-Path $RootDir 'build') -Recurse

Write-Step 'Dart package caches'

if ($All) {
    Remove-PathSafe (Join-Path $RootDir 'pubspec.lock')
} else {
    if (Test-Path -LiteralPath (Join-Path $RootDir 'pubspec.lock')) {
        Write-Info 'kept pubspec.lock (use -All to remove it)'
    }
}

Write-Host ""
Write-Host "============================================================" -ForegroundColor Green
Write-Host "  CLEAN OK" -ForegroundColor Green
Write-Host "============================================================" -ForegroundColor Green
Write-Info 'Next: run build.ps1'
exit 0