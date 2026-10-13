# =============================================================================
#  clean.ps1 — remove build artifacts and Go caches
# -----------------------------------------------------------------------------
#  Removes:
#    - go\bin\                (cross-demo executables + copied DLL)
#    - Go build cache
#    - Go test cache
#
#  Does NOT remove:
#    - ..\Binary\LingoFuse64.dll   (the canonical runtime location)
#    - go.sum / go.mod
#    - Any source files
#
#  Usage:
#    .\clean.ps1
#
#  Exit code is non-zero when any step fails.
# =============================================================================

$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot

Push-Location $root
try {
    if (Test-Path "$root\bin") {
        Write-Host "Removing $root\bin" -ForegroundColor Cyan
        Remove-Item -Recurse -Force "$root\bin"
    } else {
        Write-Host "No $root\bin to remove."
    }

    Write-Host "Cleaning Go build cache..." -ForegroundColor Cyan
    go clean -cache
    if ($LASTEXITCODE -ne 0) { throw "go clean -cache failed" }

    Write-Host "Cleaning Go test cache..." -ForegroundColor Cyan
    go clean -testcache
    if ($LASTEXITCODE -ne 0) { throw "go clean -testcache failed" }

    Write-Host ""
    Write-Host "Clean complete." -ForegroundColor Green
}
finally {
    Pop-Location
}