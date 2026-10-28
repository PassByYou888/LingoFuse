#Requires -Version 5.1
<#
.SYNOPSIS
    Run the LingoFuse Python test suite.

.DESCRIPTION
    Runs the test files under lingofuse\ in a controlled order and
    reports a per-file summary. Also runs lingofuse\_lf_native_check.py
    first to verify that the low-level ctypes bindings match the
    C ABI exports clause.

    LingoFuse is a PROCESS-GLOBAL singleton (one simulated main thread,
    one client pool, one service pool). Each test file therefore runs
    in its OWN Python subprocess by default, so a failure in one file
    cannot contaminate the next.

.PARAMETER Layer
    Which subset to run:
        all           (default) every layer
        check         only the ABI symbol check
        core          test_lingofuse.py
        async         test_async_support.py
        unit          test_bridge_units.py (L1)
        integration   test_bridge_integration.py (L2)
        e2e           test_bridge_e2e.py (L3)
        quick         check + unit + async

.PARAMETER PythonExe
    Python executable to use. Defaults to 'python'.

.PARAMETER NoE2E
    Skip the end-to-end layer. Useful when the LingoFuse shared
    library is not available.

.PARAMETER Fast
    Run all selected test files in a SINGLE pytest process. Faster,
    but cross-file state leakage is possible because LingoFuse is a
    process-global singleton. Not recommended when debugging.

.PARAMETER KeepGoing
    Continue after a test file fails. By default the script stops at
    the first failing file so the operator can inspect it before the
    global state is disturbed further.

.EXAMPLE
    .\test.ps1
    Run the full suite, one subprocess per file.

.EXAMPLE
    .\test.ps1 -Layer quick
    Run only the fast, mostly dependency-free checks.

.EXAMPLE
    .\test.ps1 -Layer integration -KeepGoing
    Run only L2 and keep going on failures.

.EXAMPLE
    .\test.ps1 -NoE2E
    Run everything except the end-to-end layer.
#>

[CmdletBinding()]
param(
    [ValidateSet('all', 'check', 'core', 'async', 'unit',
                 'integration', 'e2e', 'quick')]
    [string]$Layer = 'all',

    [string]$PythonExe = 'python',

    [switch]$NoE2E,

    [switch]$Fast,

    [switch]$KeepGoing
)

$ErrorActionPreference = 'Continue'


# ======================================================================
# Locate package root
# ======================================================================
$packageRoot = $PSScriptRoot
if (-not $packageRoot) {
    $packageRoot = (Get-Location).Path
}
$packageRoot = $packageRoot.TrimEnd('\', '/')

$lingofuseDir = Join-Path $packageRoot 'lingofuse'
$initPy = Join-Path $lingofuseDir '__init__.py'

if (-not (Test-Path $initPy)) {
    Write-Host "[FATAL] $initPy not found." -ForegroundColor Red
    Write-Host "        Run this script from the py\ directory that contains the lingofuse\ subpackage." -ForegroundColor Red
    exit 2
}

Write-Host ""
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host "  LingoFuse Python Test Suite" -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host "Package root  : $packageRoot" -ForegroundColor Gray
Write-Host "Layer         : $Layer" -ForegroundColor Gray
if ($NoE2E)    { Write-Host "NoE2E         : on (L3 will be skipped)" -ForegroundColor Gray }
if ($Fast)     { Write-Host "Fast          : on (single pytest process)" -ForegroundColor Gray }
if ($KeepGoing) { Write-Host "KeepGoing     : on" -ForegroundColor Gray }


# ======================================================================
# Python interpreter
# ======================================================================
$pythonCmd = Get-Command $PythonExe -ErrorAction SilentlyContinue
if (-not $pythonCmd) {
    Write-Host "[FATAL] '$PythonExe' is not on PATH." -ForegroundColor Red
    exit 2
}
$pythonPath = $pythonCmd.Source

$pyVer = & $pythonPath -c "import sys; print('%d.%d.%d' % sys.version_info[:3])"
if ($LASTEXITCODE -ne 0) {
    Write-Host "[FATAL] '$pythonPath -c ...' failed." -ForegroundColor Red
    exit 2
}
Write-Host "Python        : $pyVer ($pythonPath)" -ForegroundColor Gray

$pyVerParts = $pyVer.Split('.')
$pyMajor = [int]$pyVerParts[0]
$pyMinor = [int]$pyVerParts[1]
if ($pyMajor -lt 3 -or ($pyMajor -eq 3 -and $pyMinor -lt 10)) {
    Write-Host "[FATAL] Python 3.10 or later is required (got $pyVer)." -ForegroundColor Red
    exit 2
}


# ======================================================================
# PYTHONPATH (prepend package root)
# ======================================================================
$existingPyPath = [Environment]::GetEnvironmentVariable('PYTHONPATH', 'Process')
if ($existingPyPath) {
    $env:PYTHONPATH = "$packageRoot;$existingPyPath"
} else {
    $env:PYTHONPATH = $packageRoot
}
Write-Host "PYTHONPATH    : $env:PYTHONPATH" -ForegroundColor DarkGray


# ======================================================================
# Dependency probes
# ======================================================================
$pytestOk   = $false
$requestsOk = $false
$flaskOk    = $false
$importOk   = $false

Write-Host ""
Write-Host "Probing dependencies..." -ForegroundColor Cyan

& $pythonPath -c "import pytest" 2>$null
if ($LASTEXITCODE -eq 0) {
    $pytestOk = $true
    Write-Host "  pytest         : OK" -ForegroundColor Green
} else {
    Write-Host "  pytest         : MISSING" -ForegroundColor Red
}

& $pythonPath -c "import requests" 2>$null
if ($LASTEXITCODE -eq 0) {
    $requestsOk = $true
    Write-Host "  requests       : OK" -ForegroundColor Green
} else {
    Write-Host "  requests       : MISSING (E2E layer will be skipped)" -ForegroundColor Yellow
}

& $pythonPath -c "import flask" 2>$null
if ($LASTEXITCODE -eq 0) {
    $flaskOk = $true
    Write-Host "  flask          : OK" -ForegroundColor Green
} else {
    Write-Host "  flask          : MISSING (bridge tests will be skipped)" -ForegroundColor Yellow
}

& $pythonPath -c "import lingofuse" 2>$null
if ($LASTEXITCODE -eq 0) {
    $importOk = $true
    Write-Host "  lingofuse      : OK" -ForegroundColor Green
} else {
    Write-Host "  lingofuse      : IMPORT FAILED (native library missing or ABI mismatch)" -ForegroundColor Red
}

if (-not $pytestOk) {
    Write-Host ""
    Write-Host "[FATAL] pytest is required to run the tests." -ForegroundColor Red
    Write-Host "        Install it with: pip install pytest" -ForegroundColor Red
    exit 2
}


# ======================================================================
# Test catalogue
# ======================================================================
$allTests = @(
    @{ Key = 'unit';        RelPath = 'lingofuse\test_bridge_units.py';       Label = 'L1  Bridge Units';       Deps = @('native') }
    @{ Key = 'async';       RelPath = 'lingofuse\test_async_support.py';      Label = 'Async Support';          Deps = @('native') }
    @{ Key = 'core';        RelPath = 'lingofuse\test_lingofuse.py';          Label = 'Core Bindings';          Deps = @('native') }
    @{ Key = 'integration'; RelPath = 'lingofuse\test_bridge_integration.py';Label = 'L2  Bridge Integration'; Deps = @('native', 'flask') }
    @{ Key = 'e2e';         RelPath = 'lingofuse\test_bridge_e2e.py';         Label = 'L3  Bridge E2E';         Deps = @('native', 'flask', 'requests') }
)

function Select-Layer {
    param([string]$Name, [array]$Catalogue)
    switch ($Name) {
        'all'         { return $Catalogue }
        'check'       { return @() }
        'core'        { return $Catalogue | Where-Object { $_.Key -eq 'core' } }
        'async'       { return $Catalogue | Where-Object { $_.Key -eq 'async' } }
        'unit'        { return $Catalogue | Where-Object { $_.Key -eq 'unit' } }
        'integration' { return $Catalogue | Where-Object { $_.Key -eq 'integration' } }
        'e2e'         { return $Catalogue | Where-Object { $_.Key -eq 'e2e' } }
        'quick'       { return $Catalogue | Where-Object { $_.Key -in @('unit', 'async') } }
        default       { return $Catalogue }
    }
}

$selected = Select-Layer -Name $Layer -Catalogue $allTests
if ($NoE2E) {
    $selected = @($selected | Where-Object { $_.Key -ne 'e2e' })
}
$selected = @($selected)


# ======================================================================
# Helpers
# ======================================================================
function Test-NativeDepOk {
    param([string]$Dep)
    switch ($Dep) {
        'native'   { return $importOk }
        'flask'    { return $flaskOk }
        'requests' { return $requestsOk }
        default    { return $true }
    }
}

function Test-AllDepsOk {
    param([array]$Deps)
    foreach ($d in $Deps) {
        if (-not (Test-NativeDepOk -Dep $d)) { return $false }
    }
    return $true
}

function Parse-PytestSummary {
    param([string]$Output)
    $passed = 0; $failed = 0; $skipped = 0; $errors = 0
    $lines = $Output -split "`r?`n"
    $summaryLine = ($lines | Where-Object { $_ -match '(\d+)\s+passed' } | Select-Object -Last 1)
    if ($summaryLine) {
        $m = [regex]::Match($summaryLine, '(\d+)\s+passed');   if ($m.Success) { $passed  = [int]$m.Groups[1].Value }
        $m = [regex]::Match($summaryLine, '(\d+)\s+failed');   if ($m.Success) { $failed  = [int]$m.Groups[1].Value }
        $m = [regex]::Match($summaryLine, '(\d+)\s+skipped');  if ($m.Success) { $skipped = [int]$m.Groups[1].Value }
        $m = [regex]::Match($summaryLine, '(\d+)\s+error');    if ($m.Success) { $errors  = [int]$m.Groups[1].Value }
    }
    return [PSCustomObject]@{
        Passed  = $passed
        Failed  = $failed
        Skipped = $skipped
        Errors  = $errors
    }
}

function Invoke-OneTestFile {
    param(
        [string]$Root,
        [string]$Python,
        [string]$RelPath,
        [string]$Label
    )

    $absPath = Join-Path $Root $RelPath
    Write-Host ""
    Write-Host "==== $Label ====" -ForegroundColor Cyan
    Write-Host "  $RelPath" -ForegroundColor DarkGray

    if (-not (Test-Path $absPath)) {
        Write-Host "  [MISSING] $absPath" -ForegroundColor Red
        return [PSCustomObject]@{
            Label = $Label; Path = $RelPath; Status = 'MISSING'
            Passed = 0; Failed = 0; Skipped = 0; Errors = 0; ExitCode = 2
        }
    }

    $output = (& $Python -m pytest $absPath -v --tb=short 2>&1) -join "`n"
    $exitCode = $LASTEXITCODE

    Write-Host $output

    $s = Parse-PytestSummary -Output $output
    $status = if ($exitCode -eq 0) { 'PASS' } else { 'FAIL' }
    return [PSCustomObject]@{
        Label = $Label; Path = $RelPath; Status = $status
        Passed = $s.Passed; Failed = $s.Failed; Skipped = $s.Skipped; Errors = $s.Errors
        ExitCode = $exitCode
    }
}


# ======================================================================
# ABI symbol check (always runs when lingofuse is importable)
# ======================================================================
$results = @()

if ($importOk) {
    Write-Host ""
    Write-Host "==== ABI Symbol Check ====" -ForegroundColor Cyan
    $checkOut = (& $pythonPath -m lingofuse._lf_native_check 2>&1) -join "`n"
    $checkExit = $LASTEXITCODE
    Write-Host $checkOut
    $results += [PSCustomObject]@{
        Label = 'ABI Symbol Check'; Path = 'lingofuse\_lf_native_check.py'
        Status = if ($checkExit -eq 0) { 'PASS' } else { 'FAIL' }
        Passed = 0; Failed = 0; Skipped = 0; Errors = 0; ExitCode = $checkExit
    }
    if ($checkExit -ne 0) {
        Write-Host "[FAIL] ABI symbol check failed; native tests will be skipped." -ForegroundColor Red
        $importOk = $false
    }
} else {
    Write-Host ""
    Write-Host "==== ABI Symbol Check ====" -ForegroundColor Cyan
    Write-Host "  [SKIP] lingofuse import failed" -ForegroundColor Yellow
    $results += [PSCustomObject]@{
        Label = 'ABI Symbol Check'; Path = 'lingofuse\_lf_native_check.py'
        Status = 'SKIP'
        Passed = 0; Failed = 0; Skipped = 0; Errors = 0; ExitCode = 0
    }
}


# ======================================================================
# Run test files
# ======================================================================
if ($Fast -and $selected.Count -gt 1) {
    # Single combined pytest run.
    $paths = @()
    foreach ($t in $selected) {
        if (-not (Test-AllDepsOk -Deps $t.Deps)) { continue }
        $paths += (Join-Path $packageRoot $t.RelPath)
    }
    if ($paths.Count -eq 0) {
        Write-Host ""
        Write-Host "[SKIP] Fast mode: no test files have all their dependencies." -ForegroundColor Yellow
    } else {
        $label = "All Selected Tests (single process, $($paths.Count) files)"
        Write-Host ""
        Write-Host "==== $label ====" -ForegroundColor Cyan
        $output = (& $pythonPath -m pytest @paths -v --tb=short 2>&1) -join "`n"
        $exitCode = $LASTEXITCODE
        Write-Host $output
        $s = Parse-PytestSummary -Output $output
        $results += [PSCustomObject]@{
            Label = $label; Path = '<combined>'
            Status = if ($exitCode -eq 0) { 'PASS' } else { 'FAIL' }
            Passed = $s.Passed; Failed = $s.Failed; Skipped = $s.Skipped; Errors = $s.Errors
            ExitCode = $exitCode
        }
    }
} else {
    foreach ($t in $selected) {
        if (-not (Test-AllDepsOk -Deps $t.Deps)) {
            Write-Host ""
            Write-Host "==== $($t.Label) ====" -ForegroundColor Cyan
            Write-Host "  [SKIP] missing dependency" -ForegroundColor Yellow
            $results += [PSCustomObject]@{
                Label = $t.Label; Path = $t.RelPath; Status = 'SKIP'
                Passed = 0; Failed = 0; Skipped = 0; Errors = 0; ExitCode = 0
            }
            continue
        }

        $r = Invoke-OneTestFile -Root $packageRoot -Python $pythonPath `
                                -RelPath $t.RelPath -Label $t.Label
        $results += $r

        if ($r.Status -eq 'FAIL' -and -not $KeepGoing) {
            Write-Host ""
            Write-Host "Stopping at first failing file. Use -KeepGoing to run the rest." -ForegroundColor Yellow
            break
        }
    }
}


# ======================================================================
# Summary
# ======================================================================
Write-Host ""
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host "  Summary" -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host ("  {0,-30} {1,-8} {2,6} {3,6} {4,6} {5,6}" -f `
    'Test', 'Status', 'Pass', 'Fail', 'Skip', 'Error') -ForegroundColor Gray
Write-Host ("  {0,-30} {1,-8} {2,6} {3,6} {4,6} {5,6}" -f `
    '----', '------', '----', '----', '----', '-----') -ForegroundColor DarkGray

foreach ($r in $results) {
    $color = switch ($r.Status) {
        'PASS'    { 'Green' }
        'FAIL'    { 'Red' }
        'SKIP'    { 'Yellow' }
        'MISSING' { 'Magenta' }
        default   { 'Gray' }
    }
    Write-Host ("  {0,-30} {1,-8} {2,6} {3,6} {4,6} {5,6}" -f `
        $r.Label, $r.Status, $r.Passed, $r.Failed, $r.Skipped, $r.Errors) -ForegroundColor $color
}

$anyFail = @($results | Where-Object { $_.Status -in @('FAIL', 'MISSING') })
if ($anyFail.Count -gt 0) {
    Write-Host ""
    Write-Host "RESULT: FAIL" -ForegroundColor Red
    exit 1
} else {
    Write-Host ""
    Write-Host "RESULT: OK" -ForegroundColor Green
    exit 0
}