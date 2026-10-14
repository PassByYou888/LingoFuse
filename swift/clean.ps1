# =============================================================================
#  clean.ps1
# -----------------------------------------------------------------------------
#  Remove all build artifacts produced by `swift build` and `swift test`.
#
#  Steps:
#    1. Optionally set the console output encoding to UTF-8.
#    2. Run `swift package clean`.
#    3. Remove the .build directory.
#
#  The .build/index-build/ directory is normally held open by the VSCode
#  SourceKit-LSP extension. If a direct Remove-Item fails, the script
#  retries a few times and then falls back to `cmd /c rmdir /s /q`.
#
#  Usage:
#      .\clean.ps1
#      .\clean.ps1 -DryRun
#      .\clean.ps1 -Quiet
#      .\clean.ps1 -NoEncoding
#
#  Exit codes:
#      0  cleanup succeeded (or nothing to clean)
#      1  cleanup failed (some files could not be removed)
#      2  startup error (Package.swift missing)
# =============================================================================

param(
    [switch] $DryRun,
    [switch] $Quiet,
    [switch] $NoEncoding
)

$ErrorActionPreference = "Stop"

# -----------------------------------------------------------------------------
#  Console output encoding (see the same block in build.ps1).
# -----------------------------------------------------------------------------

if (-not $NoEncoding) {
    try {
        [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
        $OutputEncoding           = [System.Text.Encoding]::UTF8
    } catch { }
}

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

function Write-Err([string]$msg) {
    Write-Host "  [ERR]  $msg" -ForegroundColor Red
}

function Remove-Directory-WithRetry {
    param(
        [string] $Path,
        [int]    $MaxAttempts = 3,
        [int]    $DelayMs     = 500
    )

    if (-not (Test-Path $Path)) {
        return $true
    }

    for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
        try {
            Remove-Item -Recurse -Force -Path $Path -ErrorAction Stop
            return $true
        } catch {
            if ($attempt -lt $MaxAttempts) {
                Start-Sleep -Milliseconds $DelayMs
                continue
            }
            Write-Warn "Remove-Item failed on attempt $attempt : $_"
        }

        try {
            $null = cmd /c "rmdir /s /q `"$Path`" 2>&1"
            if (-not (Test-Path $Path)) {
                return $true
            }
            if ($attempt -lt $MaxAttempts) {
                Start-Sleep -Milliseconds $DelayMs
            }
        } catch {
            Write-Warn "cmd rmdir failed on attempt $attempt : $_"
        }
    }

    return (-not (Test-Path $Path))
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
    & swift package clean
    if ($LASTEXITCODE -ne 0) {
        Write-Warn "swift package clean returned exit code $LASTEXITCODE"
    } else {
        Write-Ok "swift package clean completed."
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
        $removed = Remove-Directory-WithRetry -Path $buildDir
        if ($removed) {
            Write-Ok "Removed $buildDir"
        } else {
            Write-Err "Could not remove $buildDir"
            Write-Info "Likely cause: VSCode's SourceKit-LSP is holding the"
            Write-Info "index database open under .build/index-build/."
            Write-Info "Try these in order:"
            Write-Info "  1. In VSCode, run 'Swift: Restart Language Server'"
            Write-Info "  2. Or run 'Developer: Reload Window'"
            Write-Info "  3. Or close VSCode and rerun this script"
            exit 1
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