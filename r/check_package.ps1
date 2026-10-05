<#
.SYNOPSIS
    Run R CMD build + R CMD check on the lingofuse package.

.DESCRIPTION
    Runs the standard R package check pipeline in a strictly offline
    mode. Both the workspace (where check runs) and the child R
    process are configured to fail any network request immediately
    rather than block.

    Before building, this script regenerates roxygen2 output
    (NAMESPACE and man/*.Rd) whenever either is missing, so that the
    "missing documentation entries" WARNING cannot appear as a side
    effect of a stale NAMESPACE. Set -NoRoxygen to skip that step.

    The offline configuration is layered:

      1. Environment variables that R CMD check consults directly.
      2. R_DEFAULT_INTERNET_TIMEOUT = 2.
      3. R_PROFILE_USER pointing at a tiny .Rprofile that overrides
         the CRAN repository with a loopback address.

    The script reports the number of WARNINGs and NOTEs found in the
    check log, and exits with R CMD check's own exit code (0 for
    WARNING/NOTE, non-zero for ERROR). It therefore behaves the same
    as R CMD check itself; it does not "promote" a WARNING into a
    failure.

.PARAMETER Keep
    Copy the built tarball and the check directory into the current
    directory after the run.

.PARAMETER NoClean
    Pass --no-clean to R CMD check.

.PARAMETER NoRoxygen
    Skip the automatic roxygen2 regeneration step. Use this when
    roxygen2 is not installed and the package's NAMESPACE and man/
    directory are already up to date.
#>

[CmdletBinding()]
param(
    [switch]$Keep,
    [switch]$NoClean,
    [switch]$NoRoxygen
)

$ErrorActionPreference = "Stop"

$Root     = $PSScriptRoot
$PkgDir   = Join-Path $Root "lingofuse"
$Rscript  = (Get-Command Rscript.exe -ErrorAction SilentlyContinue).Source
$Rexe     = (Get-Command R.exe      -ErrorAction SilentlyContinue).Source

if (-not $Rscript -or -not $Rexe) {
    Write-Host "[FAIL] R.exe or Rscript.exe not found on PATH." -ForegroundColor Red
    exit 1
}

function Write-Section { param([string]$T)
    Write-Host ""
    Write-Host ("=" * 72) -ForegroundColor Cyan
    Write-Host $T -ForegroundColor Cyan
    Write-Host ("=" * 72) -ForegroundColor Cyan
}
function Write-Ok   { param([string]$T) Write-Host ("[OK]   " + $T) -ForegroundColor Green }
function Write-Info { param([string]$T) Write-Host ("       " + $T) -ForegroundColor Gray }
function Write-Warn { param([string]$T) Write-Host ("[WARN] " + $T) -ForegroundColor Yellow }
function Write-Fail { param([string]$T) Write-Host ("[FAIL] " + $T) -ForegroundColor Red }

Write-Section "lingofuse R package - R CMD check (offline)"

# ---- Pre-flight --------------------------------------------------------------
if (-not (Test-Path $PkgDir)) {
    Write-Fail ("Package directory not found: " + $PkgDir)
    exit 1
}
Write-Ok "Package skeleton is present"

# ---- Roxygen2 regeneration (only when needed) --------------------------------
$nsPath   = Join-Path $PkgDir "NAMESPACE"
$manDir   = Join-Path $PkgDir "man"

$manEmpty = $true
if (Test-Path $manDir) {
    $manFiles = @(Get-ChildItem -Path $manDir -Filter "*.Rd" -File -ErrorAction SilentlyContinue)
    if ($manFiles.Count -gt 0) { $manEmpty = $false }
}

if ($NoRoxygen) {
    Write-Info "Roxygen2 regeneration skipped (-NoRoxygen)."
} elseif (-not (Test-Path $nsPath) -or $manEmpty) {
    Write-Section "Regenerating roxygen2 output"
    if (-not (Test-Path $nsPath)) {
        Write-Info "NAMESPACE is missing."
    }
    if ($manEmpty) {
        Write-Info "man\ contains no .Rd files."
    }
    Write-Info "Running: roxygen2::roxygenise('lingofuse')"

    Push-Location $Root
    try {
        & $Rscript "-e" "roxygen2::roxygenise('lingofuse')"
        $roxRc = $LASTEXITCODE
    } finally {
        Pop-Location
    }

    if ($roxRc -ne 0) {
        Write-Fail "roxygenise failed."
        Write-Info ""
        Write-Info "Common causes:"
        Write-Info "  - roxygen2 is not installed. Install it with:"
        Write-Info "      Rscript -e `"install.packages('roxygen2')`""
        Write-Info "  - The man\ directory is empty AND -NoRoxygen was not passed,"
        Write-Info "    but roxygen2 is unavailable."
        Write-Info ""
        Write-Info "Alternatively, re-run with -NoRoxygen to accept the current"
        Write-Info "state of NAMESPACE and man\, knowing that R CMD check will"
        Write-Info "report a 'missing documentation entries' WARNING if man\"
        Write-Info "is still empty."
        exit 1
    }
    Write-Ok "roxygen2 output regenerated."
} else {
    $manCount = @(Get-ChildItem -Path $manDir -Filter "*.Rd" -File).Count
    Write-Info ("Roxygen2 output present (NAMESPACE + " + $manCount + " .Rd file(s)).")
}

# ---- Working directory -------------------------------------------------------
$work = Join-Path $env:TEMP ("lingofuse_check_" + [Guid]::NewGuid().ToString("N").Substring(0,8))
New-Item -ItemType Directory -Path $work -Force | Out-Null

# ---- Offline R profile -------------------------------------------------------
$rProfilePath = Join-Path $work ".Rprofile-offline"
@'
# Injected by check_package.ps1 to force fully offline operation.
options(
    repos = c(CRAN = "http://127.0.0.1:1/"),
    timeout = 2,
    install.packages.check.source = "no"
)
'@ | Set-Content -Path $rProfilePath -Encoding ASCII

# ---- Offline environment (saved and restored around the check) ---------------
$savedEnv = @{}
$envVarsToSet = @{
    "_R_CHECK_FORCE_SUGGESTS_"                 = "false"
    "_R_CHECK_CRAN_INCOMING_"                  = "false"
    "_R_CHECK_CRAN_INCOMING_REMOTE_"           = "false"
    "_R_CHECK_CRAN_INCOMING_USE_ASPELL_"       = "false"
    "_R_CHECK_PACKAGE_DEPENDS_"                = "false"
    "_R_CHECK_PACKAGE_DEPENDS_USE_INSTALLED_"  = "false"
    "R_DEFAULT_INTERNET_TIMEOUT"               = "2"
    "R_PROFILE_USER"                           = $rProfilePath
}

foreach ($k in $envVarsToSet.Keys) {
    $savedEnv[$k] = [Environment]::GetEnvironmentVariable($k, "Process")
    [Environment]::SetEnvironmentVariable($k, $envVarsToSet[$k], "Process")
}

Write-Ok "Offline environment configured"
Write-Info ("R_PROFILE_USER = " + $rProfilePath)
Write-Info "CRAN repos overridden to http://127.0.0.1:1/ (fail fast)"
Write-Info "R_DEFAULT_INTERNET_TIMEOUT = 2"
Write-Info "The modified environment variables will be restored on exit."

$checkRc = 1
try {
    # ---- R CMD build ---------------------------------------------------------
    Write-Section "R CMD build"
    Push-Location $work
    try {
        & $Rexe CMD build --no-build-vignettes $PkgDir
        $buildRc = $LASTEXITCODE
    } finally {
        Pop-Location
    }

    if ($buildRc -ne 0) {
        Write-Fail ("R CMD build failed (exit code " + $buildRc + ").")
        $checkRc = $buildRc
    } else {
        $tarball = Get-ChildItem -Path $work -Filter "lingofuse_*.tar.gz" |
            Select-Object -First 1
        if (-not $tarball) {
            Write-Fail "No tarball produced by R CMD build."
            $checkRc = 1
        } else {
            Write-Ok ("Built: " + $tarball.FullName)

            # ---- R CMD check -------------------------------------------------
            Write-Section "R CMD check"
            $checkArgs = @("CMD", "check", "--no-manual", "--no-vignettes")
            if ($NoClean) {
                $checkArgs += "--no-clean"
            }
            $checkArgs += $tarball.FullName

            Push-Location $work
            try {
                & $Rexe @checkArgs
                $checkRc = $LASTEXITCODE
            } finally {
                Pop-Location
            }

            # ---- Report ------------------------------------------------------
            Write-Section "Check result"

            $checkDir = Join-Path $work "lingofuse.Rcheck"
            $logPath  = Join-Path $checkDir "00check.log"

            $warningCount = 0
            $noteCount    = 0
            $errorCount   = 0

            if (Test-Path $logPath) {
                Write-Host ""
                Write-Host "--- Tail of 00check.log ---" -ForegroundColor White
                Get-Content $logPath -Tail 60 | ForEach-Object {
                    if ($_ -match "ERROR") {
                        Write-Host $_ -ForegroundColor Red
                    } elseif ($_ -match "WARNING") {
                        Write-Host $_ -ForegroundColor Yellow
                    } elseif ($_ -match "NOTE") {
                        Write-Host $_ -ForegroundColor DarkYellow
                    } else {
                        Write-Host $_
                    }
                }

                # Count WARNINGs and NOTEs from the final "Status:" line.
                # R CMD check's log ends with either "Status: OK" or
                # "Status: N WARNINGs" / "Status: N NOTEs" /
                # "Status: N ERRORs" (possibly a combination).
                $statusLine = Get-Content $logPath -Tail 20 |
                    Select-String -Pattern "^\s*Status:" |
                    Select-Object -Last 1

                if ($statusLine) {
                    $statusText = $statusLine.Line
                    if ($statusText -match "(\d+)\s+ERROR")   { $errorCount   = [int]$Matches[1] }
                    if ($statusText -match "(\d+)\s+WARNING") { $warningCount = [int]$Matches[1] }
                    if ($statusText -match "(\d+)\s+NOTE")    { $noteCount    = [int]$Matches[1] }
                }
            } else {
                Write-Fail "No 00check.log found."
                Write-Info ("Expected at: " + $logPath)
            }

            Write-Host ""
            if ($errorCount -gt 0) {
                Write-Fail ("R CMD check reported " + $errorCount +
                            " ERROR(s), " + $warningCount +
                            " WARNING(s), " + $noteCount + " NOTE(s).")
            } elseif ($warningCount -gt 0 -or $noteCount -gt 0) {
                Write-Warn ("R CMD check completed with " + $warningCount +
                            " WARNING(s) and " + $noteCount + " NOTE(s).")
                Write-Info "The exit code is 0 because R CMD check only fails on ERROR."
                Write-Info "See 00check.log for details."
            } else {
                Write-Ok "R CMD check passed with no WARNINGs or NOTEs."
            }

            # ---- Keep or clean -----------------------------------------------
            if ($Keep) {
                $dest = Join-Path $Root ("_check_" + (Get-Date -Format "yyyyMMdd_HHmmss"))
                New-Item -ItemType Directory -Path $dest -Force | Out-Null
                Copy-Item -Force $tarball.FullName $dest
                if (Test-Path $checkDir) {
                    Copy-Item -Recurse -Force $checkDir $dest
                }
                Write-Ok ("Artifacts copied to: " + $dest)
            } else {
                try { Remove-Item -Recurse -Force $work } catch { }
                Write-Info "Working directory removed (use -Keep to retain it)."
            }
        }
    }
} finally {
    foreach ($k in $savedEnv.Keys) {
        $prev = $savedEnv[$k]
        if ($null -eq $prev) {
            [Environment]::SetEnvironmentVariable($k, $null, "Process")
        } else {
            [Environment]::SetEnvironmentVariable($k, $prev, "Process")
        }
    }
}

exit $checkRc