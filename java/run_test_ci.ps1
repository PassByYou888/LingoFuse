<#
.SYNOPSIS
    Run the LingoFuse Java binding test suite in CI mode and produce a
    machine-readable report.

.DESCRIPTION
    Wraps `mvn test -Dlingofuse.ci=true` and captures the JSON Lines
    emitted by CiTestListener. The merged stream is written to
    test_ci_report.jsonl; a compact human-readable summary is written
    to test_ci_summary.txt.

.PARAMETER Quiet
    Suppress live Maven output; only the final summary is printed.

.EXAMPLE
    .\run_test_ci.ps1
    .\run_test_ci.ps1 -Quiet
#>

[CmdletBinding()]
param(
    [switch] $Quiet
)

$ErrorActionPreference = "Stop"

# ---- 1. Locate the java project root --------------------------------
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$PomPath   = Join-Path $ScriptDir "pom.xml"

if (-not (Test-Path $PomPath)) {
    Write-Host "Cannot find pom.xml in $ScriptDir" -ForegroundColor Red
    exit 2
}

# ---- 2. Output paths ------------------------------------------------
$Report  = Join-Path $ScriptDir "test_ci_report.jsonl"
$Summary = Join-Path $ScriptDir "test_ci_summary.txt"
$RawLog  = Join-Path $ScriptDir "test_ci_raw.log"

foreach ($f in @($Report, $Summary, $RawLog)) {
    if (Test-Path $f) { Remove-Item $f -Force }
}

# ---- 3. Banner ------------------------------------------------------
Write-Host ""
Write-Host "======================================================================" -ForegroundColor Cyan
Write-Host "  LingoFuse Java -- CI test run" -ForegroundColor Cyan
Write-Host "======================================================================" -ForegroundColor Cyan
Write-Host ("  Working directory : {0}" -f $ScriptDir)
Write-Host ("  Report            : {0}" -f $Report)
Write-Host ("  Summary           : {0}" -f $Summary)
Write-Host "======================================================================" -ForegroundColor Cyan
Write-Host ""

# ---- 4. Run Maven in CI mode ---------------------------------------
# Relax EAP so a non-zero exit code is captured, not raised.
$prevEAP = $ErrorActionPreference
$ErrorActionPreference = "Continue"

try {
    if ($Quiet) {
        & mvn -B test "-Dlingofuse.ci=true" 2>&1 |
            Out-File -FilePath $RawLog -Encoding utf8
    } else {
        & mvn -B test "-Dlingofuse.ci=true" 2>&1 |
            Tee-Object -FilePath $RawLog | Out-Host
    }
    $ExitCode = $LASTEXITCODE
} finally {
    $ErrorActionPreference = $prevEAP
}

# ---- 5. Extract JSON Lines -----------------------------------------
# CiTestListener prints lines starting with '{'. Maven's own log lines
# carry an [INFO] / [ERROR] prefix, so a simple leading-brace filter
# cleanly separates the two streams.
if (Test-Path $RawLog) {
    Get-Content $RawLog -ErrorAction SilentlyContinue |
        Where-Object { $_ -match '^\s*\{' } |
        ForEach-Object { $_.Trim() } |
        Set-Content $Report -Encoding utf8
}

# ---- 6. Build the human-readable summary ---------------------------
$sb = New-Object System.Text.StringBuilder
function Add-Line([string]$s) { [void]$sb.AppendLine($s) }

Add-Line ""
Add-Line "======================================================================"
Add-Line "  LingoFuse Java -- CI Summary"
Add-Line "======================================================================"
Add-Line ""

$summaryLine = $null
if (Test-Path $Report) {
    $summaryLine = Get-Content $Report -ErrorAction SilentlyContinue |
        Where-Object { $_ -match '"event"\s*:\s*"summary"' } |
        Select-Object -Last 1
}

if ($summaryLine) {
    try {
        $s = $summaryLine | ConvertFrom-Json
        Add-Line ("  Suite   : {0}" -f $s.suite)
        Add-Line ("  Total   : {0}" -f $s.total)
        Add-Line ("  Passed  : {0}" -f $s.passed)
        Add-Line ("  Failed  : {0}" -f $s.failed)
        Add-Line ("  Time    : {0:N3} s" -f [double]$s.elapsed_sec)
        Add-Line ("  Status  : {0}" -f $s.status)
    } catch {
        Add-Line "  (could not parse summary line)"
        Add-Line "  $summaryLine"
    }
} else {
    Add-Line "  (no summary line found in the report)"
}

# List any failures.
$failLines = @()
if (Test-Path $Report) {
    $failLines = Get-Content $Report -ErrorAction SilentlyContinue |
        Where-Object { $_ -match '"event"\s*:\s*"test"' -and
                       $_ -match '"status"\s*:\s*"FAIL"' }
}

if ($failLines.Count -gt 0) {
    Add-Line ""
    Add-Line "  Failed tests:"
    Add-Line ""
    foreach ($line in $failLines) {
        try {
            $obj = $line | ConvertFrom-Json
            Add-Line ("    [{0}] {1}" -f $obj.category, $obj.name)
            if ($obj.PSObject.Properties.Name -contains "error") {
                Add-Line ("           reason: {0}" -f $obj.error)
            }
        } catch {
            Add-Line ("    {0}" -f $line)
        }
    }
}

Add-Line ""
Add-Line "======================================================================"
if ($ExitCode -eq 0) {
    Add-Line "  RESULT: ALL TESTS PASSED"
} else {
    Add-Line "  RESULT: TEST FAILURES DETECTED"
}
Add-Line "======================================================================"

$text = $sb.ToString()
Write-Host $text
$text | Out-File -FilePath $Summary -Encoding utf8

exit $ExitCode