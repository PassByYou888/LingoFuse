# =============================================================================
#  test.ps1 — run the Go test suite
# -----------------------------------------------------------------------------
#  Default: run every test (unit + integration) with verbose output.
#
#  Options:
#    -Short   skip the E2E integration tests (TestE2E_*). Useful when
#             the native runtime is unavailable or when only the pure
#             unit tests need to run.
#    -Race    enable the Go race detector. Requires a C toolchain on
#             Windows (gcc.exe on PATH).
#    -Quiet   suppress -v; show one line per package only.
#
#  Usage:
#    .\test.ps1
#    .\test.ps1 -Short
#    .\test.ps1 -Race
#    .\test.ps1 -Short -Race
#    .\test.ps1 -Quiet
#
#  Exit code is non-zero when any test fails.
# =============================================================================

[CmdletBinding()]
param(
    [switch]$Short,
    [switch]$Race,
    [switch]$Quiet
)

$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot

Push-Location $root
try {
    $goArgs = @('test', './...')

    if (-not $Quiet) {
        $goArgs += '-v'
    }
    if ($Short) {
        $goArgs += @('-skip', 'TestE2E_')
    }
    if ($Race) {
        $goArgs += '-race'
    }

    Write-Host "=== go $($goArgs -join ' ') ===" -ForegroundColor Cyan
    & go @goArgs
    if ($LASTEXITCODE -ne 0) { throw "go test failed" }

    Write-Host ""
    Write-Host "All tests passed." -ForegroundColor Green
}
finally {
    Pop-Location
}