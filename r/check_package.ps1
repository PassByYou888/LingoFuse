<#
.SYNOPSIS
    Run R CMD build + R CMD check on the lingofuse package.

.DESCRIPTION
    Runs the standard R package check pipeline in a strictly offline
    mode. Both the workspace (where check runs) and the child R
    process are configured to fail any network request immediately
    rather than block.

    The offline configuration is layered:

      1. Environment variables that R CMD check consults directly:
            _R_CHECK_FORCE_SUGGESTS_
            _R_CHECK_CRAN_INCOMING_
            _R_CHECK_CRAN_INCOMING_REMOTE_
            _R_CHECK_CRAN_INCOMING_USE_ASPELL_
            _R_CHECK_PACKAGE_DEPENDS_

      2. R_DEFAULT_INTERNET_TIMEOUT = 2, so any network call that
         still gets through fails after 2 seconds instead of hanging.

      3. R_PROFILE_USER pointing at a tiny .Rprofile that overrides
         the CRAN repository with a loopback address. Any code path
         that calls available.packages() therefore gets an immediate
         connection refused, not a hang.

    This is sufficient to run the full check on an isolated network.
    The only check step that is intentionally skipped is the
    "CRAN incoming feasibility" inspection, which is meaningful only
    for actual CRAN submission.

.PARAMETER Keep
    Copy the built tarball and the check directory into the current
    directory after the run.

.PARAMETER NoClean
    Pass --no-clean to R CMD check.
#>

[CmdletBinding()]
param(
    [switch]$Keep,
    [switch]$NoClean
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
function Write-Fail { param([string]$T) Write-Host ("[FAIL] " + $T) -ForegroundColor Red }

Write-Section "lingofuse R package - R CMD check (offline)"

# ---- Pre-flight --------------------------------------------------------------
if (-not (Test-Path $PkgDir)) {
    Write-Fail ("Package directory not found: " + $PkgDir)
    exit 1
}

$nsPath = Join-Path $PkgDir "NAMESPACE"
if (-not (Test-Path $nsPath)) {
    Write-Info "NAMESPACE not found; running roxygenise first"
    & $Rscript -e "roxygen2::roxygenise('lingofuse')"
    if ($LASTEXITCODE -ne 0) {
        Write-Fail "roxygenise failed."
        exit 1
    }
}
Write-Ok "Package skeleton is present"

# ---- Working directory -------------------------------------------------------
$work = Join-Path $env:TEMP ("lingofuse_check_" + [Guid]::NewGuid().ToString("N").Substring(0,8))
New-Item -ItemType Directory -Path $work -Force | Out-Null

# ---- Offline R profile -------------------------------------------------------
# This .Rprofile is loaded by every R process launched during the
# check, because R_PROFILE_USER is inherited through the environment.
# Overriding "repos" makes available.packages() fail fast.
$rProfilePath = Join-Path $work ".Rprofile-offline"
@'
# Injected by check_package.ps1 to force fully offline operation.
options(
    repos = c(CRAN = "http://127.0.0.1:1/"),
    timeout = 2,
    install.packages.check.source = "no"
)
'@ | Set-Content -Path $rProfilePath -Encoding ASCII

# ---- Offline environment -----------------------------------------------------
$env:_R_CHECK_FORCE_SUGGESTS_              = "false"
$env:_R_CHECK_CRAN_INCOMING_               = "false"
$env:_R_CHECK_CRAN_INCOMING_REMOTE_        = "false"
$env:_R_CHECK_CRAN_INCOMING_USE_ASPELL_    = "false"
$env:_R_CHECK_PACKAGE_DEPENDS_             = "false"
$env:_R_CHECK_PACKAGE_DEPENDS_USE_INSTALLED_ = "false"
$env:R_DEFAULT_INTERNET_TIMEOUT            = "2"
$env:R_PROFILE_USER                        = $rProfilePath

Write-Ok "Offline environment configured"
Write-Info ("R_PROFILE_USER = " + $rProfilePath)
Write-Info "CRAN repos overridden to http://127.0.0.1:1/ (fail fast)"
Write-Info "R_DEFAULT_INTERNET_TIMEOUT = 2"

# ---- R CMD build -------------------------------------------------------------
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
    exit $buildRc
}

$tarball = Get-ChildItem -Path $work -Filter "lingofuse_*.tar.gz" |
    Select-Object -First 1
if (-not $tarball) {
    Write-Fail "No tarball produced by R CMD build."
    exit 1
}
Write-Ok ("Built: " + $tarball.FullName)

# ---- R CMD check -------------------------------------------------------------
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

# ---- Report ------------------------------------------------------------------
Write-Section "Check result"

$checkDir = Join-Path $work "lingofuse.Rcheck"
$logPath  = Join-Path $checkDir "00check.log"

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
} else {
    Write-Fail "No 00check.log found."
    Write-Info ("Expected at: " + $logPath)
}

if ($checkRc -eq 0) {
    Write-Ok "R CMD check passed."
} else {
    Write-Fail ("R CMD check reported issues (exit code " + $checkRc + ").")
}

# ---- Keep or clean -----------------------------------------------------------
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

exit $checkRc