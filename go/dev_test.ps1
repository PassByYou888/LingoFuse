# =============================================================================
#  dev_test.ps1 — fast developer feedback loop
# -----------------------------------------------------------------------------
#  A short, opinionated sequence for iterating on the Go binding. Runs
#  in a few seconds on a warm build cache and surfaces the most common
#  problems immediately:
#
#    1. go build ./...      catch compile errors
#    2. go vet ./...        catch static-analysis warnings
#    3. go test ./... -count=1
#                           run every test, no caching
#
#  The test cache is disabled so that a source change is always
#  reflected in the result. Unlike test.ps1, this script does NOT pass
#  -v: the goal is a quick green/red signal, not a full report. Run
#  test.ps1 when you want the detailed output.
#
#  Usage:
#    .\dev_test.ps1
#
#  Exit code is non-zero when any step fails.
# =============================================================================

[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot

Push-Location $root
try {
    Write-Host "=== go build ./... ===" -ForegroundColor Cyan
    go build ./...
    if ($LASTEXITCODE -ne 0) { throw "go build failed" }

    Write-Host "=== go vet ./... ===" -ForegroundColor Cyan
    go vet ./...
    if ($LASTEXITCODE -ne 0) { throw "go vet failed" }

    Write-Host "=== go test ./... -count=1 ===" -ForegroundColor Cyan
    go test ./... -count=1
    if ($LASTEXITCODE -ne 0) { throw "go test failed" }

    Write-Host ""
    Write-Host "Dev loop passed." -ForegroundColor Green
}
finally {
    Pop-Location
}