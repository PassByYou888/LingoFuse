<#
.SYNOPSIS
    Uninstall the lingofuse R package.

.DESCRIPTION
    Removes the lingofuse package from the R library. Two modes:

        Default        Calls R's own remove.packages(), which is the
                       only correct way to fully uninstall (it also
                       cleans up metadata in the library directory).

        -Force         If remove.packages() fails (typically a
                       permission error), fall back to deleting the
                       package directory manually. NOT recommended as
                       the first option, because residual metadata may
                       remain in the library index.

    If the package is not installed, the script reports this and exits
    with status 0 (nothing to do is not a failure).

.PARAMETER Library
    Look for the package in this library directory instead of R's
    default.

.PARAMETER Force
    Fall back to manually deleting the package directory if
    remove.packages() fails.

.PARAMETER Quiet
    Suppress per-step informational messages.

.EXAMPLE
    .\uninstall_package.ps1

.EXAMPLE
    .\uninstall_package.ps1 -Force

.EXAMPLE
    .\uninstall_package.ps1 -Library "$env:USERPROFILE\R\win-library\4.6"
#>

[CmdletBinding()]
param(
    [string]$Library,
    [switch]$Force,
    [switch]$Quiet
)

$ErrorActionPreference = "Stop"

$Rexe    = (Get-Command R.exe -ErrorAction SilentlyContinue).Source
$Rscript = (Get-Command Rscript.exe -ErrorAction SilentlyContinue).Source

function Write-Section { param([string]$T)
    Write-Host ""
    Write-Host ("=" * 72) -ForegroundColor Cyan
    Write-Host $T -ForegroundColor Cyan
    Write-Host ("=" * 72) -ForegroundColor Cyan
}
function Write-Ok   { param([string]$T) Write-Host ("[OK]   " + $T) -ForegroundColor Green }
function Write-Info { param([string]$T) if (-not $Quiet) { Write-Host ("       " + $T) -ForegroundColor Gray } }
function Write-Warn { param([string]$T) Write-Host ("[WARN] " + $T) -ForegroundColor Yellow }
function Write-Fail { param([string]$T) Write-Host ("[FAIL] " + $T) -ForegroundColor Red }

Write-Section "lingofuse - uninstall"

# ---- Pre-flight --------------------------------------------------------------
if (-not $Rexe -or -not $Rscript) {
    Write-Fail "R.exe or Rscript.exe not found on PATH."
    exit 1
}

# ---- Detect whether the package is installed --------------------------------
$libArg = if ($Library) { $Library } else { "" }
$libArgEscaped = $libArg -replace '\\', '/' -replace "'", "\\'"

$detectScript = @"
lib <- '$libArgEscaped'
if (nzchar(lib)) {
    p <- find.package('lingofuse', lib.loc = lib, quiet = TRUE)
} else {
    p <- find.package('lingofuse', quiet = TRUE)
}
if (length(p) > 0) cat(p) else cat('')
"@

$pkgPath = (& $Rscript "-e" $detectScript) -join ""
$pkgPath = $pkgPath.Trim()

if (-not $pkgPath) {
    if ($Library) {
        Write-Info ("lingofuse is not installed in: " + $Library)
    } else {
        Write-Info "lingofuse is not installed in any library on .libPaths()."
    }
    Write-Ok "Nothing to uninstall."
    exit 0
}

Write-Ok ("Found: " + $pkgPath)

# ---- remove.packages() ------------------------------------------------------
Write-Section "Running remove.packages()"

$removeScript = @"
lib <- '$libArgEscaped'
if (nzchar(lib)) {
    remove.packages('lingofuse', lib = lib)
} else {
    remove.packages('lingofuse')
}
"@

$removeErr = $null
try {
    & $Rscript "-e" $removeScript 2>&1 | ForEach-Object {
        if (-not $Quiet) { Write-Info $_ }
    }
    $removeRc = $LASTEXITCODE
} catch {
    $removeErr = $_.Exception.Message
    $removeRc = 1
}

$stillInstalled = $false
if ($removeRc -ne 0) {
    if ($removeErr) { Write-Warn ("remove.packages() raised: " + $removeErr) }
    Write-Warn "remove.packages() failed."
    $stillInstalled = $true
} else {
    # Double-check.
    $recheck = (& $Rscript "-e" $detectScript) -join ""
    if ($recheck.Trim()) {
        $stillInstalled = $true
    }
}

# ---- Fallback: -Force -------------------------------------------------------
if ($stillInstalled -and $Force) {
    Write-Section "Forcing removal of " + $pkgPath

    Write-Warn "Manually deleting the package directory."
    Write-Warn "Residual library metadata (e.g. 00LOCK-lingofuse) may remain."

    try {
        Remove-Item -Recurse -Force $pkgPath
        Write-Ok ("Deleted: " + $pkgPath)

        # Clean up any leftover lock directory in the same library.
        $libRoot = Split-Path -Parent $pkgPath
        $lockDir = Join-Path $libRoot "00LOCK-lingofuse"
        if (Test-Path $lockDir) {
            Remove-Item -Recurse -Force $lockDir
            Write-Ok ("Deleted: " + $lockDir)
        }
    } catch {
        Write-Fail ("Failed to delete " + $pkgPath + ": " + $_.Exception.Message)
        Write-Info "Try running as Administrator."
        exit 1
    }
}

if ($stillInstalled -and -not $Force) {
    Write-Section "Failed"
    Write-Fail "Package is still installed."
    Write-Info ""
    Write-Info "Common causes:"
    Write-Info "  - The library is under C:\Program Files\ and you are not running"
    Write-Info "    as Administrator."
    Write-Info "  - A previous R session still has the package attached."
    Write-Info ""
    Write-Info "Options:"
    Write-Info "  1. Re-run this script as Administrator."
    Write-Info "  2. Re-run with -Force to delete the directory manually."
    exit 1
}

# ---- Final verification -----------------------------------------------------
Write-Section "Verification"

$finalCheck = (& $Rscript "-e" $detectScript) -join ""
if ($finalCheck.Trim()) {
    Write-Fail ("Package still present at: " + $finalCheck.Trim())
    exit 1
}
Write-Ok "lingofuse successfully uninstalled."

Write-Section "Done"
Write-Host ""

exit 0