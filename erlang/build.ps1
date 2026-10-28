#Requires -Version 5.1

[CmdletBinding()]
param(
    [switch]$SkipNif,
    [switch]$Clean
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$global:LASTEXITCODE = 0

$ScriptDir = $PSScriptRoot
$Rebar3    = Join-Path $ScriptDir 'rebar3.cmd'

if (-not (Test-Path -Path $Rebar3 -PathType Leaf)) {
    Write-Host "[FATAL] rebar3.cmd not found next to build.ps1" -ForegroundColor Red
    Write-Host "        Expected: $Rebar3" -ForegroundColor Red
    exit 1
}

function Invoke-Step {
    param(
        [Parameter(Mandatory = $true)][string]$Label,
        [Parameter(Mandatory = $true)][scriptblock]$Body
    )
    Write-Host ''
    Write-Host "==> $Label" -ForegroundColor Cyan
    $code = 0
    try {
        & $Body | Out-Host
        if ($null -ne $LASTEXITCODE) { $code = $LASTEXITCODE }
    } catch {
        Write-Host "    exception: $($_.Exception.Message)" -ForegroundColor Red
        $code = 1
    }
    if ($code -eq 0) {
        Write-Host "[ OK ] $Label" -ForegroundColor Green
    } else {
        Write-Host "[FAIL] $Label (exit code $code)" -ForegroundColor Red
    }
    return $code
}

if ($Clean) {
    $cleanScript = Join-Path $ScriptDir 'clean.ps1'
    if (-not (Test-Path -Path $cleanScript -PathType Leaf)) {
        Write-Host "[FATAL] clean.ps1 not found, cannot honor -Clean" -ForegroundColor Red
        exit 1
    }
    $code = Invoke-Step -Label 'pre-clean' -Body { & $cleanScript }
    if ($code -ne 0) { exit $code }
}

if ($SkipNif) {
    $env:LINGOFUSE_SKIP_NIF = '1'
    Write-Host '[info] -SkipNif: LINGOFUSE_SKIP_NIF=1' -ForegroundColor Yellow
} elseif ($env:LINGOFUSE_SKIP_NIF) {
    Write-Host "[info] LINGOFUSE_SKIP_NIF already set: $env:LINGOFUSE_SKIP_NIF" -ForegroundColor Yellow
} else {
    Write-Host '[info] NIF compilation enabled' -ForegroundColor Yellow
}

Push-Location $ScriptDir
try {
    $code = Invoke-Step -Label 'rebar3 compile' -Body { & $Rebar3 compile }
} finally {
    Pop-Location
}

if ($code -ne 0) { exit $code }

Write-Host ''
Write-Host 'Build completed successfully.' -ForegroundColor Green
exit 0