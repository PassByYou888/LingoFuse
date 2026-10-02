# =============================================================================
#  clean.ps1 — remove build artifacts and Go caches
# -----------------------------------------------------------------------------
#  Removes:
#    - go\bin\                (built cross-demo executables)
#    - Go build cache
#    - Go test cache
#
#  Does NOT remove:
#    - go\LingoFuse64.dll     (manually placed; keep it)
#    - go.sum / go.mod
#    - Any source files
#
#  Usage:
#    .\clean.ps1
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