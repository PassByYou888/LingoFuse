# =============================================================================
#  test.ps1 — run the Go test suite
# -----------------------------------------------------------------------------
#  Default: run every test (unit + integration) with verbose output and
#  test caching disabled (-count=1), so a code change is always reflected
#  in the result.
#
#  The suite under go/test/ is split into:
#
#    * Pure Go tests (no native library required)
#    * Native-library tests (skipped when the DLL is unavailable)
#      - ABI smoke tests (TestLibraryLoads, TestDataHandleRoundtrip,
#        TestPermanentHandle)
#      - ABI probe tests (TestProbe*)
#      - DataHandle / JSON round-trips
#      - End-to-end framework tests (TestE2E_*)
#      - Option round-trips
#      - Async dispatch-failure path
#
#  Options:
#    -Short   skip every test that requires the native library
#             (TestE2E_* and TestProbe*).
#    -Probe   run ONLY the ABI probe tests. Useful after an upgrade of
#             the shared library to verify that the [32]byte UID
#             argument is still passed correctly.
#    -Race    enable the Go race detector. Requires a C toolchain.
#    -Quiet   suppress -v; show one line per package only.
#
#  Usage:
#    .\test.ps1
#    .\test.ps1 -Short
#    .\test.ps1 -Probe
#    .\test.ps1 -Race
#    .\test.ps1 -Short -Race
#    .\test.ps1 -Quiet
#
#  Exit code is non-zero when any test fails.
# =============================================================================

[CmdletBinding()]
param(
    [switch]$Short,
    [switch]$Probe,
    [switch]$Race,
    [switch]$Quiet
)

$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot

function Write-Stage {
    param([string]$Text)
    Write-Host ""
    Write-Host ("=" * 72) -ForegroundColor DarkGray
    Write-Host "  $Text" -ForegroundColor Cyan
    Write-Host ("=" * 72) -ForegroundColor DarkGray
}

Push-Location $root
try {
    # -------------------------------------------------------------------------
    # Stage 1 — describe what we are about to run
    # -------------------------------------------------------------------------
    Write-Stage "LingoFuse Go test suite"

    $mode = if ($Probe) { "ABI probe only" }
            elseif ($Short) { "short (skip native-dependent tests)" }
            else { "full (unit + integration)" }
    Write-Host "  mode       : $mode"
    Write-Host "  verbose    : $(-not $Quiet)"
    Write-Host "  race       : $Race"
    Write-Host "  count      : 1 (test cache disabled)"
    Write-Host "  working dir: $root"

    # -------------------------------------------------------------------------
    # Stage 2 — build the argument list
    # -------------------------------------------------------------------------
    $goArgs = @('test', './...', '-count=1')

    if (-not $Quiet) {
        $goArgs += '-v'
    }

    if ($Probe) {
        $goArgs += @('-run', 'TestProbe')
    } elseif ($Short) {
        $goArgs += @('-skip', 'TestE2E_|TestProbe')
    }

    if ($Race) {
        $goArgs += '-race'
    }

    # -------------------------------------------------------------------------
    # Stage 3 — run
    # -------------------------------------------------------------------------
    Write-Stage "go $($goArgs -join ' ')"

    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    & go @goArgs
    $exitCode = $LASTEXITCODE
    $sw.Stop()

    # -------------------------------------------------------------------------
    # Stage 4 — report
    # -------------------------------------------------------------------------
    Write-Stage "Result"

    Write-Host ("  elapsed : {0:N2} s" -f $sw.Elapsed.TotalSeconds)

    if ($exitCode -eq 0) {
        Write-Host "  status  : PASS" -ForegroundColor Green
        Write-Host ""
        Write-Host "All tests passed." -ForegroundColor Green
    } else {
        Write-Host "  status  : FAIL" -ForegroundColor Red
        Write-Host ""
        throw "go test failed (exit code $exitCode)"
    }
}
finally {
    Pop-Location
}