# test.ps1 - Run every acceptance test in the test/ directory.
#
# The script scans test/*.jl and runs each one in a fresh Julia
# subprocess with --threads=2, which is REQUIRED by the callback
# consumer (see SHIM_MECHANISM_GUIDE.md, rule 7).
#
# Automatically excluded:
#   runtests.jl    the standard Julia test entry point; it re-runs
#                  every other script and would cause duplicates.
#
# Any other *.jl file in test/ is executed, including the diagnostic
# scripts (diag.jl, try_module.jl) and the restart regression test
# (test_restart.jl). To exclude a file permanently, add its name to
# the $exclude array below.
#
# Exit code:
#   0  all tests passed
#   1  one or more tests failed, or an unexpected error occurred

$ErrorActionPreference = "Stop"

$here    = Split-Path -Parent $MyInvocation.MyCommand.Definition
$testDir = Join-Path $here "test"

Write-Host "====================================================================" -ForegroundColor Magenta
Write-Host "  LingoFuse Julia Binding - Test Suite" -ForegroundColor Magenta
Write-Host "====================================================================" -ForegroundColor Magenta
Write-Host ""

# --- Locate Julia ---------------------------------------------------------

$juliaCmd = Get-Command "julia" -ErrorAction SilentlyContinue
if (-not $juliaCmd) {
    Write-Host "[FAIL] 'julia' not found on PATH." -ForegroundColor Red
    Write-Host "       Add the Julia bin directory to PATH and retry." -ForegroundColor Yellow
    exit 1
}
Write-Host "[INFO] Julia   : $($juliaCmd.Source)" -ForegroundColor Cyan
Write-Host "[INFO] Test dir: $testDir" -ForegroundColor Cyan

# --- Discover tests -------------------------------------------------------
#
# Scan test/*.jl sorted alphabetically for a stable execution order.
# Files whose name appears in $exclude are skipped.
#
# The exclusion list is intentionally minimal. runtests.jl is the only
# file that would cause duplicate execution, because it invokes every
# other script through a nested subprocess.

$exclude = @(
    "runtests.jl"
)

$files = Get-ChildItem -Path $testDir -Filter "*.jl" -File |
    Where-Object { $exclude -notcontains $_.Name } |
    Sort-Object Name

if ($files.Count -eq 0) {
    Write-Host "[FAIL] No test files found in $testDir" -ForegroundColor Red
    exit 1
}

Write-Host "[INFO] Found $($files.Count) test file(s):" -ForegroundColor Cyan
foreach ($f in $files) {
    Write-Host "         - $($f.Name)" -ForegroundColor DarkGray
}
Write-Host ""

# --- Run each test --------------------------------------------------------

$results   = @()
$anyFailed = $false

foreach ($f in $files) {
    Write-Host "====================================================================" -ForegroundColor White
    Write-Host "  Running: $($f.Name)" -ForegroundColor White
    Write-Host "====================================================================" -ForegroundColor White
    Write-Host ""

    $startTime = Get-Date
    & $juliaCmd.Source --threads=2 $f.FullName
    $exitCode = $LASTEXITCODE
    $elapsed  = (Get-Date) - $startTime

    if ($exitCode -eq 0) {
        Write-Host ""
        Write-Host "  [$($f.Name)] PASS  ($([math]::Round($elapsed.TotalSeconds, 2)) s)" -ForegroundColor Green
        $results += [PSCustomObject]@{
            Name   = $f.Name
            Status = "PASS"
            Time   = $elapsed.TotalSeconds
        }
    } else {
        Write-Host ""
        Write-Host "  [$($f.Name)] FAIL  (exit=$exitCode)  ($([math]::Round($elapsed.TotalSeconds, 2)) s)" -ForegroundColor Red
        $results += [PSCustomObject]@{
            Name   = $f.Name
            Status = "FAIL"
            Time   = $elapsed.TotalSeconds
        }
        $anyFailed = $true
    }
}

# --- Summary --------------------------------------------------------------

Write-Host ""
Write-Host "====================================================================" -ForegroundColor Magenta
Write-Host "  Summary" -ForegroundColor Magenta
Write-Host "====================================================================" -ForegroundColor Magenta
Write-Host ""

Write-Host ("  {0,-25} {1,-8} {2}" -f "Test", "Status", "Time (s)") -ForegroundColor White
Write-Host ("  {0,-25} {1,-8} {2}" -f ("-" * 25), ("-" * 8), ("-" * 10)) -ForegroundColor DarkGray

foreach ($r in $results) {
    $timeStr = if ($null -ne $r.Time) { [math]::Round($r.Time, 2) } else { "-" }
    $color   = switch ($r.Status) {
        "PASS"  { "Green"  }
        "FAIL"  { "Red"    }
        "SKIP"  { "Yellow" }
        default { "White"  }
    }
    Write-Host ("  {0,-25} {1,-8} {2}" -f $r.Name, $r.Status, $timeStr) -ForegroundColor $color
}

Write-Host ""
if ($anyFailed) {
    Write-Host "  RESULT: FAILED" -ForegroundColor Red
    exit 1
} else {
    Write-Host "  RESULT: ALL PASSED" -ForegroundColor Green
    exit 0
}