<#
.SYNOPSIS
    Full verification of the LingoFuse Fortran binding.

.DESCRIPTION
    Cleans, builds, and runs every test executable in c_ext.
    Reports a single PASS/FAIL verdict.

    Does NOT run the cross_demo programs, because they require
    manually started service and node processes. Use
    run_cross_demo.ps1 for those.
#>

[CmdletBinding()]
param()

$ErrorActionPreference = 'Continue'

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$ExtDir    = Join-Path $ScriptDir 'c_ext'

$overallExit = 0

function Section {
    param([string]$Title)
    Write-Host ''
    Write-Host ('=' * 72) -ForegroundColor Cyan
    Write-Host ("  " + $Title) -ForegroundColor Cyan
    Write-Host ('=' * 72) -ForegroundColor Cyan
}

# ---------------------------------------------------------------------------
# 1. Clean
# ---------------------------------------------------------------------------
Section "1. Clean"
& (Join-Path $ScriptDir 'clean.ps1')

# ---------------------------------------------------------------------------
# 2. Build
# ---------------------------------------------------------------------------
Section "2. Build"
& (Join-Path $ScriptDir 'build.ps1') -Target c_ext
if ($LASTEXITCODE -ne 0) {
    Write-Host ''
    Write-Host '[FATAL] Build failed.' -ForegroundColor Red
    exit 2
}

# ---------------------------------------------------------------------------
# 3. Run each test
# ---------------------------------------------------------------------------
$tests = @(
    @{ Name = 'C ABI test';              Exe = 'test_lf_fortran_c.exe' },
    @{ Name = 'Fortran binding test';    Exe = 'test_lf_fortran_f.exe' },
    @{ Name = 'Fortran JSON test';       Exe = 'test_lf_json_f.exe'   },
    @{ Name = 'Task-handle async test';  Exe = 'test_lf_tasks_f.exe'  }
)

$summary = @()

foreach ($t in $tests) {
    Section ("3. " + $t.Name)
    $exePath = Join-Path $ExtDir $t.Exe

    if (-not (Test-Path -LiteralPath $exePath)) {
        Write-Host ("[SKIP] not found: {0}" -f $exePath) -ForegroundColor Yellow
        $summary += [PSCustomObject]@{
            Test   = $t.Name
            Status = 'SKIP'
            Detail = 'executable missing'
        }
        $overallExit = 1
        continue
    }

    Push-Location -LiteralPath $ExtDir
    try {
        & $exePath | Out-Host
        $rc = $LASTEXITCODE
    }
    finally {
        Pop-Location
    }

    if ($rc -eq 0) {
        $summary += [PSCustomObject]@{
            Test   = $t.Name
            Status = 'PASS'
            Detail = ''
        }
    }
    else {
        $summary += [PSCustomObject]@{
            Test   = $t.Name
            Status = 'FAIL'
            Detail = ("exit code {0}" -f $rc)
        }
        $overallExit = 1
    }
}

# ---------------------------------------------------------------------------
# 4. Final summary
# ---------------------------------------------------------------------------
Section "4. Final summary"

Write-Host ''
Write-Host ('  {0,-30} {1,-8} {2}' -f 'Test', 'Status', 'Detail')
Write-Host ('  {0,-30} {1,-8} {2}' -f ('-' * 30), ('-' * 8), ('-' * 24))

foreach ($row in $summary) {
    $color = switch ($row.Status) {
        'PASS' { 'Green' }
        'FAIL' { 'Red' }
        'SKIP' { 'Yellow' }
        default { 'Gray' }
    }
    Write-Host ('  {0,-30} {1,-8} {2}' -f $row.Test, $row.Status, $row.Detail) `
        -ForegroundColor $color
}

Write-Host ''
if ($overallExit -eq 0) {
    Write-Host '[OK] All c_ext tests passed.' -ForegroundColor Green
    Write-Host ''
    Write-Host 'To run the cross-language demo:' -ForegroundColor Cyan
    Write-Host '    .\run_cross_demo.ps1'
}
else {
    Write-Host '[ERROR] One or more tests failed.' -ForegroundColor Red
}

exit $overallExit