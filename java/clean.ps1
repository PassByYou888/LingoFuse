<#
.SYNOPSIS
    Clean build artifacts and JVM crash dumps for the LingoFuse Java binding.

.DESCRIPTION
    Removes:
      - the Maven target directory,
      - JVM crash logs (hs_err_pid*.log, hs_err_pid*.mdmp),
      - surefire dump streams,
      - Maven replay logs.

    Safe to run at any time. Every removal is best-effort: a file that
    cannot be deleted (for example, locked by another process) produces
    a warning but does not stop the script.

.PARAMETER KeepTarget
    Skip deletion of the Maven target directory. Use this when you only
    want to remove crash dumps and other temporary files.

.EXAMPLE
    .\clean.ps1
    .\clean.ps1 -KeepTarget
#>

[CmdletBinding()]
param(
    [switch]$KeepTarget
)

$ErrorActionPreference = 'Continue'

# --- Output helpers ---------------------------------------------------------

function Write-Info  { param([string]$m) Write-Host "[INFO]  $m" -ForegroundColor Cyan }
function Write-Ok    { param([string]$m) Write-Host "[OK]    $m" -ForegroundColor Green }
function Write-Warn2 { param([string]$m) Write-Host "[WARN]  $m" -ForegroundColor Yellow }

$script:removedCount = 0

function Remove-Safe {
    param(
        [Parameter(Mandatory=$true)][string]$Path,
        [switch]$Recurse
    )
    if (-not (Test-Path -LiteralPath $Path)) {
        return
    }
    try {
        if ($Recurse) {
            Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction Stop
        } else {
            Remove-Item -LiteralPath $Path -Force -ErrorAction Stop
        }
        Write-Ok "Removed: $Path"
        $script:removedCount++
    } catch {
        Write-Warn2 "Could not remove $Path : $($_.Exception.Message)"
    }
}

# --- Header -----------------------------------------------------------------

Write-Info "=== LingoFuse Java binding - clean ==="
Write-Info "Working directory: $(Get-Location)"
Write-Info ""

# --- 1. Maven target directory ---------------------------------------------

if ($KeepTarget) {
    Write-Info "Skipped target/ (KeepTarget specified)"
} else {
    Remove-Safe -Path "target" -Recurse
}

# --- 2. JVM crash logs ------------------------------------------------------

Get-ChildItem -Path "." -Filter "hs_err_pid*.log" -File -ErrorAction SilentlyContinue | ForEach-Object {
    Remove-Safe -Path $_.FullName
}
Get-ChildItem -Path "." -Filter "hs_err_pid*.mdmp" -File -ErrorAction SilentlyContinue | ForEach-Object {
    Remove-Safe -Path $_.FullName
}

# --- 3. surefire dump streams (only present under target/) -----------------

if (Test-Path -LiteralPath "target") {
    Get-ChildItem -Path "target" -Filter "*.dumpstream" -File -Recurse -ErrorAction SilentlyContinue | ForEach-Object {
        Remove-Safe -Path $_.FullName
    }
    Get-ChildItem -Path "target" -Filter "*.dump" -File -Recurse -ErrorAction SilentlyContinue | ForEach-Object {
        Remove-Safe -Path $_.FullName
    }
}

# --- Summary ----------------------------------------------------------------

Write-Info ""
if ($script:removedCount -eq 0) {
    Write-Ok "Already clean. Nothing to remove."
} else {
    Write-Ok "Clean complete. $script:removedCount item(s) removed."
}