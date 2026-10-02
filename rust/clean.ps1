<#
.SYNOPSIS
    Clean build artifacts from the lingofuse Rust crate.

.DESCRIPTION
    Removes the target/ directory. With no arguments, only the debug
    profile is removed. Use -Release to remove only the release
    profile, or -AllProfiles to remove the entire target/ directory
    (debug + release + incremental).

    The script never touches the native LingoFuse library. If the
    library happens to sit in the crate root, it is left alone; the
    operator is responsible for its placement.

    This script lives in the crate root. It uses $PSScriptRoot to
    locate the crate.

.PARAMETER AllProfiles
    Remove the entire target/ directory.

.PARAMETER Release
    Remove only target/release. Ignored if -AllProfiles is set.

.PARAMETER DryRun
    Print what would be removed without actually removing anything.

.EXAMPLE
    .\clean.ps1
    Removes target/debug.

.EXAMPLE
    .\clean.ps1 -Release
    Removes target/release.

.EXAMPLE
    .\clean.ps1 -AllProfiles
    Removes the entire target directory.

.EXAMPLE
    .\clean.ps1 -AllProfiles -DryRun
    Prints the paths that would be removed.
#>

[CmdletBinding()]
param(
    [switch]$AllProfiles,
    [switch]$Release,
    [switch]$DryRun
)

$ErrorActionPreference = "Stop"

$CrateRoot = $PSScriptRoot
Set-Location $CrateRoot

# ---------------------------------------------------------------------------
# Banner
# ---------------------------------------------------------------------------
Write-Host ""
Write-Host "===============================================" -ForegroundColor Cyan
Write-Host " LingoFuse Rust - Clean" -ForegroundColor Cyan
Write-Host "===============================================" -ForegroundColor Cyan
Write-Host " Crate root    : $CrateRoot"
Write-Host " All profiles  : $AllProfiles"
Write-Host " Release only  : $Release"
Write-Host " Dry run       : $DryRun"
Write-Host ""

# ---------------------------------------------------------------------------
# Determine what to remove
# ---------------------------------------------------------------------------
$targetDir = Join-Path $CrateRoot "target"
$pathsToRemove = @()

if ($AllProfiles) {
    if (Test-Path $targetDir) {
        $pathsToRemove += $targetDir
    }
} else {
    $profileDir = if ($Release) {
        Join-Path $targetDir "release"
    } else {
        Join-Path $targetDir "debug"
    }
    if (Test-Path $profileDir) {
        $pathsToRemove += $profileDir
    }
}

if ($pathsToRemove.Count -eq 0) {
    Write-Host "[INFO] Nothing to clean." -ForegroundColor Green
    Write-Host ""
    exit 0
}

# ---------------------------------------------------------------------------
# Report what will be removed
# ---------------------------------------------------------------------------
Write-Host "[INFO] Paths to remove:" -ForegroundColor Cyan
foreach ($p in $pathsToRemove) {
    $size = $null
    try {
        if (Test-Path $p -PathType Container) {
            $bytes = (Get-ChildItem $p -Recurse -File -ErrorAction SilentlyContinue |
                      Measure-Object -Property Length -Sum).Sum
            if ($bytes) { $size = "{0:N2} MB" -f ($bytes / 1MB) }
        } else {
            $bytes = (Get-Item $p).Length
            $size = "{0:N2} MB" -f ($bytes / 1MB)
        }
    } catch {
        $size = "unknown"
    }
    Write-Host ("       {0}  ({1})" -f $p, $size)
}
Write-Host ""

if ($DryRun) {
    Write-Host "[INFO] Dry run: no files were removed." -ForegroundColor Yellow
    Write-Host ""
    exit 0
}

# ---------------------------------------------------------------------------
# Remove
# ---------------------------------------------------------------------------
$removed = 0
$failed = @()

foreach ($p in $pathsToRemove) {
    Write-Host "[STEP] Removing $p" -ForegroundColor Cyan
    try {
        Remove-Item -Path $p -Recurse -Force -ErrorAction Stop
        $removed += 1
        Write-Host "[OK]   Removed." -ForegroundColor Green
    } catch {
        Write-Host "[FAIL] $($_.Exception.Message)" -ForegroundColor Red
        $failed += $p
    }
}

# ---------------------------------------------------------------------------
# Report
# ---------------------------------------------------------------------------
Write-Host ""
Write-Host "===============================================" -ForegroundColor Cyan
if ($failed.Count -eq 0) {
    Write-Host (" Removed {0} path(s)." -f $removed) -ForegroundColor Green
    Write-Host "===============================================" -ForegroundColor Cyan
    exit 0
} else {
    Write-Host (" Removed {0} path(s); {1} failed." -f $removed, $failed.Count) -ForegroundColor Red
    Write-Host "===============================================" -ForegroundColor Cyan
    exit 1
}