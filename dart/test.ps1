#Requires -Version 5.1
[CmdletBinding()]
param(
    [switch]$SkipAnalyze,
    [switch]$SkipUnit,
    [switch]$SkipPhase,
    [switch]$SkipDemo,
    [string]$LingoFuseBinDir = 'D:\CoreLibrary\LingoFuse\Binary'
)

$ErrorActionPreference = 'Continue'
$RootDir = $PSScriptRoot
$BridgeDir = Join-Path $RootDir 'bridge'

$script:TotalPass = 0
$script:TotalFail = 0
$script:FailedTests = @()

function Write-Step { param([string]$Msg) Write-Host ""; Write-Host ">>> $Msg" -ForegroundColor Cyan }
function Write-Pass { param([string]$Msg) Write-Host "[PASS] $Msg" -ForegroundColor Green }
function Write-Fail { param([string]$Msg) Write-Host "[FAIL] $Msg" -ForegroundColor Red }
function Write-Info { param([string]$Msg) Write-Host "[info] $Msg" -ForegroundColor DarkGray }

function Get-FileHashShort {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return '(missing)' }
    try {
        $h = Get-FileHash -LiteralPath $Path -Algorithm SHA256
        return $h.Hash.Substring(0, 12)
    } catch {
        return '(hash-failed)'
    }
}

function Invoke-TestStep {
    param(
        [string]$Name,
        [scriptblock]$Action
    )
    Write-Step $Name
    $global:LASTEXITCODE = 0
    try {
        & $Action
    } catch {
        Write-Fail "$Name (exception: $_)"
        $script:TotalFail++
        $script:FailedTests += $Name
        return
    }
    $rc = $global:LASTEXITCODE
    if ($rc -ne 0) {
        Write-Fail "$Name (exit $rc)"
        $script:TotalFail++
        $script:FailedTests += $Name
    } else {
        Write-Pass $Name
        $script:TotalPass++
    }
}

Write-Host "============================================================"
Write-Host "  test.ps1  (LingoFuse Dart binding)"
Write-Host "  RootDir         : $RootDir"
Write-Host "  LingoFuseBinDir : $LingoFuseBinDir"
Write-Host "  PSVersion       : $($PSVersionTable.PSVersion)"
Write-Host "============================================================"

Write-Step 'Preconditions'

if (-not (Test-Path (Join-Path $LingoFuseBinDir 'LingoFuse64.dll'))) {
    Write-Fail "LingoFuse64.dll not found at $LingoFuseBinDir"
    Write-Info 'Set -LingoFuseBinDir or run build.ps1 first'
    exit 1
}
Write-Info "LingoFuse64.dll found"

if (-not (Test-Path (Join-Path $BridgeDir 'lf_dart_bridge.dll'))) {
    Write-Fail "lf_dart_bridge.dll missing under $BridgeDir; run build.ps1 first"
    exit 1
}
Write-Info "lf_dart_bridge.dll found"

if (-not (Test-Path (Join-Path $RootDir '.dart_tool'))) {
    Write-Fail ".dart_tool missing; run build.ps1 first"
    exit 1
}
Write-Info ".dart_tool present"

$env:PATH = "$LingoFuseBinDir;$env:PATH"
Write-Info "prepended $LingoFuseBinDir to PATH for child processes"

Write-Step 'File fingerprints'
$fingerprintTargets = @(
    'test\server_test.dart',
    'test\call_context_test.dart',
    'test\data_handle_test.dart',
    'test\io_test.dart',
    'test\status_test.dart',
    'lib\src\bridge\bridge_host.dart',
    'bridge\lf_dart_bridge.dll'
)
foreach ($f in $fingerprintTargets) {
    $abs = Join-Path $RootDir $f
    $hash = Get-FileHashShort -Path $abs
    Write-Info ("{0,-40} sha256[:12]={1}" -f $f, $hash)
}

Push-Location $RootDir
try {
    if (-not $SkipAnalyze) {
        Invoke-TestStep 'dart analyze' {
            & dart analyze
        }
    } else {
        Write-Info 'skipped: dart analyze'
    }

    if (-not $SkipUnit) {
        $unitTests = @(
            'test\data_handle_test.dart',
            'test\io_test.dart',
            'test\status_test.dart',
            'test\server_test.dart',
            'test\call_context_test.dart'
        )
        foreach ($t in $unitTests) {
            $rel = $t
            $abs = Join-Path $RootDir $t
            if (-not (Test-Path -LiteralPath $abs)) {
                Write-Info "missing $rel, skipping"
                continue
            }
            $hash = Get-FileHashShort -Path $abs
            Invoke-TestStep "unit: $rel [sha256[:12]=$hash]" {
                & dart test $abs
            }
        }
    } else {
        Write-Info 'skipped: unit tests'
    }

    if (-not $SkipPhase) {
        $phaseTests = @(
            'bin\phase1_test.dart',
            'bin\phase2_test.dart',
            'bin\phase3_test.dart',
            'bin\phase4_bridge_probe.dart',
            'bin\phase5_framework_test.dart',
            'bin\phase6_async_probe.dart',
            'bin\phase7_addressing_probe.dart'
        )
        foreach ($t in $phaseTests) {
            $rel = $t
            $abs = Join-Path $RootDir $t
            if (-not (Test-Path -LiteralPath $abs)) {
                Write-Info "missing $rel, skipping"
                continue
            }
            $hash = Get-FileHashShort -Path $abs
            Invoke-TestStep "phase: $rel [sha256[:12]=$hash]" {
                & dart run $abs
            }
        }
    } else {
        Write-Info 'skipped: phase tests'
    }

    if (-not $SkipDemo) {
        $demo = 'bin\hello_async.dart'
        $abs = Join-Path $RootDir $demo
        if (Test-Path -LiteralPath $abs) {
            $hash = Get-FileHashShort -Path $abs
            Invoke-TestStep "demo: $demo [sha256[:12]=$hash]" {
                & dart run $abs
            }
        } else {
            Write-Info "missing $demo, skipping"
        }
    } else {
        Write-Info 'skipped: demo'
    }

} finally {
    Pop-Location
}

Write-Host ""
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host "  TEST SUMMARY" -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host "  Pass: $script:TotalPass"
Write-Host "  Fail: $script:TotalFail"

if ($script:TotalFail -gt 0) {
    Write-Host "  Failed steps:" -ForegroundColor Red
    foreach ($t in $script:FailedTests) {
        Write-Host "    - $t" -ForegroundColor Red
    }
    exit 1
}

Write-Host "  All tests passed." -ForegroundColor Green
exit 0