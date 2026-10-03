# =============================================================================
#  clean.ps1
# -----------------------------------------------------------------------------
#  Remove all build artifacts produced by `swift build` and `swift test`.
#
#  Steps:
#    1. Run `swift package clean` to drop the SwiftPM index and caches.
#    2. Remove the .build directory (which also removes any native
#       library copied by `build.ps1 -CopyNative`).
#
#  Usage:
#      .\clean.ps1
#      .\clean.ps1 -DryRun
#      .\clean.ps1 -Quiet
#
#  Exit codes:
#      0  cleanup succeeded (or nothing to clean)
#      1  cleanup failed
#      2  startup error (Package.swift missing)
# =============================================================================

param(
    [switch] $DryRun,
    [switch] $Quiet
)

$ErrorActionPreference = "Stop"

# -----------------------------------------------------------------------------
#  Helpers
# -----------------------------------------------------------------------------

function Write-Section([string]$title) {
    if ($Quiet) { return }
    Write-Host ""
    Write-Host "======================================================================" -ForegroundColor Cyan
    Write-Host "  $title" -ForegroundColor Cyan
    Write-Host "======================================================================" -ForegroundColor Cyan
}

function Write-Info([string]$msg) {
    if ($Quiet) { return }
    Write-Host "  $msg"
}

function Write-Ok([string]$msg) {
    Write-Host "  [OK]   $msg" -ForegroundColor Green
}

function Write-Warn([string]$msg) {
    Write-Host "  [WARN] $msg" -ForegroundColor Yellow
}

# -----------------------------------------------------------------------------
#  1. Locate the project root
# -----------------------------------------------------------------------------

$ProjectDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$ManifestPath = Join-Path $ProjectDir "Package.swift"

if (-not (Test-Path $ManifestPath)) {
    Write-Host "[FATAL] Package.swift not found in $ProjectDir" -ForegroundColor Red
    exit 2
}

# -----------------------------------------------------------------------------
#  2. Banner
# -----------------------------------------------------------------------------

Write-Section "LingoFuse Swift Clean"
Write-Info "Project directory: $ProjectDir"
if ($DryRun) {
    Write-Info "Mode             : DRY RUN (no files will be removed)"
}

# -----------------------------------------------------------------------------
#  3. Run swift package clean
# -----------------------------------------------------------------------------

Write-Section "swift package clean"

if ($DryRun) {
    Write-Info "[DRY RUN] swift package clean"
} else {
    try {
        & swift package clean
        if ($LASTEXITCODE -ne 0) {
            Write-Warn "swift package clean returned exit code $LASTEXITCODE"
        } else {
            Write-Ok "swift package clean completed."
        }
    } catch {
        Write-Warn "swift package clean threw: $_"
    }
}

# -----------------------------------------------------------------------------
#  4. Remove the .build directory
# -----------------------------------------------------------------------------

Write-Section "Remove .build"

$buildDir = Join-Path $ProjectDir ".build"

if (-not (Test-Path $buildDir)) {
    Write-Info ".build directory does not exist; nothing to remove."
} else {
    if ($DryRun) {
        Write-Info "[DRY RUN] Remove-Item -Recurse -Force $buildDir"
    } else {
        try {
            Remove-Item -Recurse -Force $buildDir
            Write-Ok "Removed $buildDir"
        } catch {
            Write-Warn "Failed to remove $buildDir : $_"
        }
    }
}

# -----------------------------------------------------------------------------
#  5. Done
# -----------------------------------------------------------------------------

Write-Section "Done"
Write-Info "Cleanup complete."
Write-Info "Next steps:"
Write-Info "    .\build.ps1 -CopyNative"
Write-Info "    .\test.ps1"

exit 0