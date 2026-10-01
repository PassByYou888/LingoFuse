# =============================================================================
#  run_test_ci.ps1
# -----------------------------------------------------------------------------
#  One-shot CI orchestration for the LingoFuse C++ functional test suites on
#  Windows.
#
#  It runs:
#      test_lingofuse.exe       --ci  (42 ABI / RAII / network tests)
#      test_lingofuse_json.exe  --ci  (40 lf_io / wire-format tests)
#
#  Each suite emits one JSON line per test plus a final summary line. The
#  script merges both streams into a single report, then prints a compact
#  human-readable table.
#
#  Usage:
#      .\run_test_ci.ps1
#      .\run_test_ci.ps1 -Quiet
#      .\run_test_ci.ps1 -SkipNetwork
#
#  Exit codes:
#      0  every test in every suite PASSed
#      1  at least one test FAILed
#      2  startup error (missing exe, missing runtime library, ...)
# =============================================================================

param(
    [switch] $Quiet,
    [switch] $SkipNetwork,
    [switch] $SkipJson
)

$ErrorActionPreference = "Stop"

# ---- 1. Locate the Binary directory ----------------------------------------
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path

$Candidates = @(
    $ScriptDir,
    (Join-Path $ScriptDir "..\..\Binary"),
    (Join-Path $ScriptDir "..\Binary"),
    (Join-Path $ScriptDir "Binary")
)

$Bin = $null
foreach ($c in $Candidates) {
    if (-not (Test-Path $c)) { continue }
    $resolved = (Resolve-Path $c).Path
    if (Test-Path (Join-Path $resolved "test_lingofuse.exe")) {
        $Bin = $resolved
        break
    }
}

if (-not $Bin) {
    Write-Host "Could not locate test_lingofuse.exe. Searched:" -ForegroundColor Red
    foreach ($c in $Candidates) {
        Write-Host "    $c" -ForegroundColor Red
    }
    Write-Host ""
    Write-Host "Build the project first:" -ForegroundColor Yellow
    Write-Host "    cd LingoFuse\cpp; mkdir build; cd build" -ForegroundColor Yellow
    Write-Host "    cmake .. -DCMAKE_BUILD_TYPE=Release" -ForegroundColor Yellow
    Write-Host "    cmake --build . --config Release" -ForegroundColor Yellow
    exit 2
}

# ---- 2. Output files -------------------------------------------------------
$Report      = Join-Path $ScriptDir "test_ci_report.jsonl"
$SummaryFile = Join-Path $ScriptDir "test_ci_summary.txt"
$LogA        = Join-Path $ScriptDir "test_ci_lingofuse.jsonl"
$LogB        = Join-Path $ScriptDir "test_ci_lingofuse_json.jsonl"

foreach ($f in @($Report, $SummaryFile, $LogA, $LogB)) {
    if (Test-Path $f) { Remove-Item $f -Force }
}

# ---- 3. Banner -------------------------------------------------------------
Write-Host ""
Write-Host "======================================================================" -ForegroundColor Cyan
Write-Host "  LingoFuse Functional Test -- CI run (Windows)" -ForegroundColor Cyan
Write-Host "======================================================================" -ForegroundColor Cyan
Write-Host ("  Binary directory : {0}" -f $Bin)
Write-Host ("  Report           : {0}" -f $Report)
Write-Host ("  Summary          : {0}" -f $SummaryFile)
Write-Host "======================================================================" -ForegroundColor Cyan
Write-Host ""

# ---- 4. Suite runner -------------------------------------------------------
#  A suite is a name + path pair. It runs the executable with --ci and
#  captures stdout to a JSON Lines file, then returns the exit code.

$Suites = @()

if (-not $SkipNetwork) {
    $exe = Join-Path $Bin "test_lingofuse.exe"
    if (Test-Path $exe) {
        $Suites += @{
            Name     = "test_lingofuse"
            Title    = "ABI / RAII / network suite (42 tests)"
            Exe      = $exe
            LogFile  = $LogA
        }
    }
    else {
        Write-Host "  WARNING: test_lingofuse.exe not found, skipping." -ForegroundColor Yellow
    }
}

if (-not $SkipJson) {
    $exe = Join-Path $Bin "test_lingofuse_json.exe"
    if (Test-Path $exe) {
        $Suites += @{
            Name     = "test_lingofuse_json"
            Title    = "lf_io / wire-format suite (40 tests)"
            Exe      = $exe
            LogFile  = $LogB
        }
    }
    else {
        Write-Host "  WARNING: test_lingofuse_json.exe not found, skipping." -ForegroundColor Yellow
    }
}

if ($Suites.Count -eq 0) {
    Write-Host "No test suites found to run." -ForegroundColor Red
    exit 2
}

# ---- 5. Run each suite -----------------------------------------------------
$SuiteResults = @()
$OverallExit  = 0

foreach ($s in $Suites) {
    Write-Host ("  Running {0}" -f $s.Title) -ForegroundColor Yellow
    Write-Host ("           {0} --ci" -f $s.Exe) -ForegroundColor DarkGray
    Write-Host ""

    $previousErrorAction = $ErrorActionPreference
    $ErrorActionPreference = "Continue"

    try {
        if ($Quiet) {
            & $s.Exe --ci 2>&1 | Out-File -FilePath $s.LogFile -Encoding utf8
        } else {
            & $s.Exe --ci 2>&1 | Tee-Object -FilePath $s.LogFile | Out-Host
        }
        $exitCode = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $previousErrorAction
    }

    # Parse the summary line.
    $summary = $null
    if (Test-Path $s.LogFile) {
        $summaryLine = Get-Content $s.LogFile -ErrorAction SilentlyContinue |
            Where-Object { $_ -match '"event"\s*:\s*"summary"' } |
            Select-Object -Last 1
        if ($summaryLine) {
            try { $summary = $summaryLine | ConvertFrom-Json } catch {}
        }
    }

    $SuiteResults += @{
        Suite   = $s
        Exit    = $exitCode
        Summary = $summary
    }

    if ($exitCode -ne 0) {
        $OverallExit = 1
    }

    Write-Host ""
}

# ---- 6. Merge JSON Lines into one report -----------------------------------
foreach ($sr in $SuiteResults) {
    if (Test-Path $sr.Suite.LogFile) {
        Get-Content $sr.Suite.LogFile -ErrorAction SilentlyContinue |
            Add-Content $Report
    }
}

# ---- 7. Build summary table ------------------------------------------------
$table = New-Object System.Text.StringBuilder
function Add-Line([string]$s) { [void]$table.AppendLine($s) }

Add-Line ""
Add-Line "======================================================================"
Add-Line "  LingoFuse Functional Test -- CI Summary"
Add-Line "======================================================================"
Add-Line ""
Add-Line ("  {0,-28} {1,8} {2,8} {3,8} {4,10} {5,8}" -f `
          "Suite", "Total", "Passed", "Failed", "Time(s)", "Status")
Add-Line ("  {0,-28} {1,8} {2,8} {3,8} {4,10} {5,8}" -f `
          ("-" * 28), ("-" * 8), ("-" * 8), ("-" * 8), ("-" * 10), ("-" * 8))

$grand_total = 0
$grand_passed = 0
$grand_failed = 0
$grand_elapsed = 0.0

foreach ($sr in $SuiteResults) {
    if ($null -ne $sr.Summary) {
        $s = $sr.Summary
        $grand_total   += [int]$s.total
        $grand_passed  += [int]$s.passed
        $grand_failed  += [int]$s.failed
        $grand_elapsed += [double]$s.elapsed_sec
        Add-Line ("  {0,-28} {1,8} {2,8} {3,8} {4,10:N2} {5,8}" -f `
                  $sr.Suite.Name, $s.total, $s.passed, $s.failed,
                  [double]$s.elapsed_sec, $s.status)
    } else {
        Add-Line ("  {0,-28} {1,8} {2,8} {3,8} {4,10} {5,8}" -f `
                  $sr.Suite.Name, "?", "?", "?", "?", "NO_DATA")
    }
}

Add-Line ("  {0,-28} {1,8} {2,8} {3,8} {4,10} {5,8}" -f `
          ("-" * 28), ("-" * 8), ("-" * 8), ("-" * 8), ("-" * 10), ("-" * 8))
Add-Line ("  {0,-28} {1,8} {2,8} {3,8} {4,10:N2} {5,8}" -f `
          "TOTAL", $grand_total, $grand_passed, $grand_failed,
          $grand_elapsed, $(if ($grand_failed -eq 0) { "PASS" } else { "FAIL" }))

Add-Line ""

# List any failures.
$failedLines = @()
if (Test-Path $Report) {
    $failedLines = Get-Content $Report -ErrorAction SilentlyContinue |
        Where-Object { $_ -match '"event"\s*:\s*"test"' -and
                       $_ -match '"status"\s*:\s*"FAIL"' }
}

if ($failedLines.Count -gt 0) {
    Add-Line "  Failed tests:"
    Add-Line ""
    foreach ($line in $failedLines) {
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
    Add-Line ""
}

Add-Line "======================================================================"
Add-Line "  Artifacts"
Add-Line "======================================================================"
Add-Line ("    Combined report  : {0}" -f $Report)
Add-Line ("    Summary          : {0}" -f $SummaryFile)
foreach ($sr in $SuiteResults) {
    Add-Line ("    {0,-17}: {1}" -f $sr.Suite.Name, $sr.Suite.LogFile)
}
Add-Line ""

if ($OverallExit -eq 0) {
    Add-Line "  RESULT: ALL TESTS PASSED"
} else {
    Add-Line "  RESULT: ONE OR MORE TESTS FAILED"
}
Add-Line "======================================================================"

$tableText = $table.ToString()
Write-Host $tableText
$tableText | Out-File -FilePath $SummaryFile -Encoding utf8

Write-Host ""
if ($OverallExit -eq 0) {
    Write-Host "  RESULT: ALL TESTS PASSED" -ForegroundColor Green
} else {
    Write-Host "  RESULT: ONE OR MORE TESTS FAILED" -ForegroundColor Red
}
Write-Host ""

exit $OverallExit