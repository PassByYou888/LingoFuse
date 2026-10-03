# =============================================================================
#  clean.ps1 - Remove build artifacts, caches, and smoke test log files.
# -----------------------------------------------------------------------------
#  Removed
#  -------
#    .zig-cache/    - the Zig build cache
#    zig-out/       - the install directory produced by `zig build`
#    *.log          - smoke test log files written to the project root
#
#  Preserved
#  ---------
#    Everything under src/, examples/, tests/, and c/ is left untouched.
#    In particular, c/json.hpp and the LingoFuse C ABI source files are
#    NOT removed. Source files are never touched by this script.
#
#  Parameters
#  ----------
#    -KeepLogs   Preserves the *.log files produced by the smoke tests.
#    -DryRun     Prints what would be removed without deleting anything.
#
#  Exit codes
#  ----------
#    0  cleanup completed
#
#  Example
#  -------
#    .\clean.ps1
#    .\clean.ps1 -DryRun
#    .\clean.ps1 -KeepLogs
# =============================================================================

[CmdletBinding()]
param(
    [switch]$KeepLogs,
    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'

# -----------------------------------------------------------------------------
# Move to the script's own directory.
# -----------------------------------------------------------------------------
$Root = $PSScriptRoot
Set-Location $Root

# -----------------------------------------------------------------------------
# Helper: remove a single path, printing one status line.
# -----------------------------------------------------------------------------
function Remove-ItemSafe {
    param(
        [string]$Path,
        [string]$Label
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        Write-Host "  [skip] $Label (not present)"
        return
    }

    if ($DryRun) {
        Write-Host "  [dry ] would remove $Label"
        return
    }

    try {
        Remove-Item -LiteralPath $Path -Recurse -Force
        Write-Host "  [done] removed $Label" -ForegroundColor Green
    } catch {
        Write-Host "  [fail] $Label : $($_.Exception.Message)" -ForegroundColor Red
    }
}

Write-Host "================================================================"
Write-Host "  LingoFuse Zig binding - clean"
Write-Host "================================================================"
Write-Host "  Project root : $Root"
Write-Host "  Dry run      : $($DryRun.IsPresent)"
Write-Host "  Keep logs    : $($KeepLogs.IsPresent)"
Write-Host "================================================================"

# -----------------------------------------------------------------------------
# Build artifacts and caches.
# -----------------------------------------------------------------------------
Write-Host ""
Write-Host "Removing build artifacts and caches..."
Remove-ItemSafe -Path (Join-Path $Root '.zig-cache') -Label '.zig-cache/'
Remove-ItemSafe -Path (Join-Path $Root 'zig-out')    -Label 'zig-out/'

# -----------------------------------------------------------------------------
# Smoke test log files.
# -----------------------------------------------------------------------------
Write-Host ""

if ($KeepLogs) {
    Write-Host "Preserving *.log files (-KeepLogs was specified)."
} else {
    Write-Host "Removing smoke test log files..."

    $logs = @(Get-ChildItem -Path $Root -Filter '*.log' -File -ErrorAction SilentlyContinue)
    if ($logs.Count -eq 0) {
        Write-Host "  [skip] no *.log files present"
    } else {
        foreach ($log in $logs) {
            if ($DryRun) {
                Write-Host "  [dry ] would remove $($log.Name)"
            } else {
                try {
                    Remove-Item -LiteralPath $log.FullName -Force
                    Write-Host "  [done] removed $($log.Name)" -ForegroundColor Green
                } catch {
                    Write-Host "  [fail] $($log.Name) : $($_.Exception.Message)" -ForegroundColor Red
                }
            }
        }
    }
}

# -----------------------------------------------------------------------------
# Summary.
# -----------------------------------------------------------------------------
Write-Host ""
Write-Host "================================================================"
if ($DryRun) {
    Write-Host "  Cleanup dry run complete. No files were removed." -ForegroundColor Yellow
} else {
    Write-Host "  Cleanup complete." -ForegroundColor Green
}
Write-Host "================================================================"

exit 0