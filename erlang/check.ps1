#Requires -Version 5.1
<#
.SYNOPSIS
    Static analysis for the LingoFuse Erlang NIF binding.

.DESCRIPTION
    Runs a configurable set of static checks against the project.

    Default suite (fast):
        compile    - syntax and compiler warnings (erl_lint)
        style      - lightweight in-script style scan
        xref       - cross-reference analysis
        hank       - dead-code detection
        escript    - syntax check of cross/*.escript

    Optional suites:
        fmt --check   - formatting check  (enable with -Format)
        dialyzer      - type analysis     (enable with -Dialyzer)

    This script forces LINGOFUSE_SKIP_NIF=1 for the duration of the
    run. Static checks do not need the compiled NIF.

    About the `style` stage
    -----------------------
    The Elvis linter (rebar3_lint) is intentionally not used: its
    configuration format changes between elvis_core releases. The
    style stage below covers the same high-value rules that a NIF
    binding project actually cares about, entirely in PowerShell and
    with no third-party dependency:

        * no trailing whitespace
        * no tab characters
        * no lines longer than 120 characters

    Every violation is printed as FILE:LINE: DESCRIPTION and the
    stage fails when at least one violation is found.

.PARAMETER All
    Enable every check: fmt --check and dialyzer included.

.PARAMETER Dialyzer
    Enable the dialyzer check. The first run builds the PLT; on
    Windows this can take 20-30 minutes.

.PARAMETER Format
    Enable the read-only fmt --check step.

.PARAMETER Fix
    Run fmt --write instead of fmt --check. This rewrites source
    files in place. Mutually exclusive with -Format.

.PARAMETER SkipEscript
    Skip the cross/*.escript syntax check.

.PARAMETER SkipStyle
    Skip the in-script style scan.

.EXAMPLE
    .\check.ps1
    Run the default fast suite.

.EXAMPLE
    .\check.ps1 -All
    Run every check.

.EXAMPLE
    .\check.ps1 -Fix
    Auto-format the code, then run the default suite.
#>

[CmdletBinding()]
param(
    [switch]$All,
    [switch]$Dialyzer,
    [switch]$Format,
    [switch]$Fix,
    [switch]$SkipEscript,
    [switch]$SkipStyle
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$global:LASTEXITCODE = 0

if ($Format -and $Fix) {
    Write-Host '[FATAL] -Format and -Fix are mutually exclusive.' -ForegroundColor Red
    exit 1
}

if ($All) {
    $Format   = $true
    $Dialyzer = $true
}

# --- Paths -----------------------------------------------------------------

$ScriptDir  = $PSScriptRoot
$Rebar3     = Join-Path $ScriptDir 'rebar3.cmd'
$EscriptChk = Join-Path $ScriptDir 'cross\check_escript.escript'

if (-not (Test-Path -Path $Rebar3 -PathType Leaf)) {
    Write-Host '[FATAL] rebar3.cmd not found next to check.ps1' -ForegroundColor Red
    exit 1
}

# Static checks do not require the C side.
$env:LINGOFUSE_SKIP_NIF = '1'

# --- Style scan configuration ----------------------------------------------

# The three style rules covered by the in-script scan. Keep them
# narrow and high-signal; broaden only when a real need appears.
$StyleMaxLineLength = 120
$StyleSourceGlobs   = @('src\*.erl', 'test\*.erl')

# --- Result collection -----------------------------------------------------

$script:Results = New-Object System.Collections.Generic.List[object]

function Add-Result {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$Status,
        [int]$Code = 0
    )
    [void]$script:Results.Add(
        [pscustomobject]@{ Name = $Name; Status = $Status; Code = $Code })
}

function Invoke-Check {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][scriptblock]$Body
    )
    Write-Host ''
    Write-Host "==> $Name" -ForegroundColor Cyan
    $code = 0
    try {
        & $Body
        if ($null -ne $LASTEXITCODE) { $code = $LASTEXITCODE }
    } catch {
        Write-Host "    exception: $($_.Exception.Message)" -ForegroundColor Red
        $code = 1
    }
    if ($code -eq 0) {
        Write-Host "[ OK ] $Name" -ForegroundColor Green
        Add-Result -Name $Name -Status 'PASS' -Code 0
    } else {
        Write-Host "[FAIL] $Name (exit code $code)" -ForegroundColor Red
        Add-Result -Name $Name -Status 'FAIL' -Code $code
    }
}

# --- In-script style scan --------------------------------------------------
#
# Covers three high-value rules that Elvis would otherwise provide.
# The scan is intentionally read-only: it reports but never rewrites
# files. Auto-formatting is the job of `rebar3 fmt --write`.

function Get-StyleViolations {
    param([string[]]$Files)

    $violations = New-Object System.Collections.Generic.List[string]

    foreach ($file in $Files) {
        $lineNo = 0
        foreach ($line in [System.IO.File]::ReadAllLines($file)) {
            $lineNo++

            # Rule 1: no trailing whitespace.
            if ($line -match '[ \t]+$') {
                [void]$violations.Add(
                    ("{0}:{1}: trailing whitespace" -f $file, $lineNo))
            }

            # Rule 2: no tab characters anywhere in the line.
            if ($line -match "`t") {
                [void]$violations.Add(
                    ("{0}:{1}: tab character" -f $file, $lineNo))
            }

            # Rule 3: line length limit.
            if ($line.Length -gt $StyleMaxLineLength) {
                [void]$violations.Add(
                    ("{0}:{1}: line length {2} > {3}" `
                        -f $file, $lineNo, $line.Length, $StyleMaxLineLength))
            }
        }
    }
    return ,$violations
}

function Invoke-StyleScan {
    $files = New-Object System.Collections.Generic.List[string]
    foreach ($pattern in $StyleSourceGlobs) {
        $resolved = Get-ChildItem -Path (Join-Path $ScriptDir $pattern) `
                                  -File -ErrorAction SilentlyContinue
        foreach ($f in $resolved) {
            [void]$files.Add($f.FullName)
        }
    }

    if ($files.Count -eq 0) {
        Write-Host '    no source files matched the style scan globs'
        return 0
    }

    Write-Host ("    scanning {0} file(s) with {1} rule(s)" `
                -f $files.Count, 3)

    $violations = Get-StyleViolations -Files $files.ToArray()
    if ($violations.Count -eq 0) {
        Write-Host '    no style violations'
        return 0
    }

    Write-Host ("    {0} style violation(s):" -f $violations.Count) `
        -ForegroundColor Yellow
    foreach ($v in $violations) {
        Write-Host ("      {0}" -f $v) -ForegroundColor Yellow
    }
    return 1
}

# --- Optional auto-fix (must run before other checks) ----------------------

Push-Location $ScriptDir
try {
    if ($Fix) {
        Invoke-Check -Name 'fmt --write' -Body { & $Rebar3 fmt --write }
    }

    # --- Default suite -----------------------------------------------------

    Invoke-Check -Name 'compile' -Body { & $Rebar3 compile }

    if (-not $SkipStyle) {
        Invoke-Check -Name 'style' -Body {
            $styleCode = Invoke-StyleScan
            if ($styleCode -ne 0) { throw "style scan failed" }
        }
    }

    Invoke-Check -Name 'xref' -Body { & $Rebar3 xref }
    Invoke-Check -Name 'hank' -Body { & $Rebar3 hank }

    # --- Optional: formatting check ----------------------------------------

    if ($Format) {
        Invoke-Check -Name 'fmt --check' -Body { & $Rebar3 fmt --check }
    }

    # --- Optional: dialyzer -------------------------------------------------

    if ($Dialyzer) {
        Invoke-Check -Name 'dialyzer' -Body { & $Rebar3 dialyzer }
    }

    # --- Optional: escript syntax check ------------------------------------

    if (-not $SkipEscript) {
        $escriptCmd = Get-Command escript -ErrorAction SilentlyContinue
        if ($null -eq $escriptCmd) {
            Write-Host ''
            Write-Host '==> escript check' -ForegroundColor Cyan
            Write-Host '    [SKIP] escript not found in PATH' -ForegroundColor Yellow
            Add-Result -Name 'escript' -Status 'SKIP' -Code 0
        } elseif (-not (Test-Path -Path $EscriptChk -PathType Leaf)) {
            Write-Host ''
            Write-Host '==> escript check' -ForegroundColor Cyan
            Write-Host "    [SKIP] $EscriptChk not found" -ForegroundColor Yellow
            Add-Result -Name 'escript' -Status 'SKIP' -Code 0
        } else {
            Invoke-Check -Name 'escript' -Body { & escript $EscriptChk }
        }
    }
} finally {
    Pop-Location
}

# --- Summary ---------------------------------------------------------------

Write-Host ''
Write-Host '============================================================' -ForegroundColor Cyan
Write-Host '  Static analysis summary'                                   -ForegroundColor Cyan
Write-Host '============================================================' -ForegroundColor Cyan

$maxName = 10
foreach ($r in $script:Results) {
    if ($r.Name.Length -gt $maxName) { $maxName = $r.Name.Length }
}

foreach ($r in $script:Results) {
    $padded = $r.Name.PadRight($maxName)
    $color = switch ($r.Status) {
        'PASS' { 'Green' }
        'FAIL' { 'Red' }
        'SKIP' { 'Yellow' }
        default { 'Gray' }
    }
    Write-Host ("  {0}   {1}" -f $padded, $r.Status) -ForegroundColor $color
}

# @(...) forces an array so that .Count works even when the filter
# matches zero or one element.
$passCount = @($script:Results | Where-Object { $_.Status -eq 'PASS' }).Count
$failCount = @($script:Results | Where-Object { $_.Status -eq 'FAIL' }).Count
$skipCount = @($script:Results | Where-Object { $_.Status -eq 'SKIP' }).Count

Write-Host ''
Write-Host ("  passed: {0}   failed: {1}   skipped: {2}" `
            -f $passCount, $failCount, $skipCount) -ForegroundColor Cyan
Write-Host ''

if ($failCount -gt 0) {
    Write-Host 'Result: FAILED' -ForegroundColor Red
    exit 1
}

Write-Host 'Result: OK' -ForegroundColor Green
exit 0