<#
.SYNOPSIS
    Install the lingofuse R package.

.DESCRIPTION
    Installs the lingofuse package from one of two sources:

        (a) The package source tree under .\lingofuse\. Used by default.
        (b) A pre-built .tar.gz passed via -Tarball.

    This script does NOT copy sources from c_ext\src\ into lingofuse\src\
    and does NOT recompile anything. If you have changed any of the C /
    C++ sources, run .\build_package.ps1 -Rebuild instead: it performs
    the copy step and then delegates to R CMD INSTALL.

    Post-install, the script loads the package in a fresh R process to
    verify that it can be attached and that the expected functions are
    present. Pass -NoTest to skip this step.

.PARAMETER Tarball
    Path to a lingofuse_<ver>.tar.gz. When specified, the script installs
    that tarball and ignores the source tree.

.PARAMETER Library
    Install into this library directory instead of R's default. On
    Windows, the default is typically
    C:\Program Files\R\R-x.y.z\library and requires Administrator
    privileges; specify -Library to install elsewhere.

.PARAMETER NoTest
    Skip the post-install verification step.

.EXAMPLE
    .\install_package.ps1

.EXAMPLE
    .\install_package.ps1 -Library "$env:USERPROFILE\R\win-library\4.6"

.EXAMPLE
    .\install_package.ps1 -Tarball .\_check_20261005_222457\lingofuse_0.5.0.tar.gz
#>

[CmdletBinding()]
param(
    [string]$Tarball,
    [string]$Library,
    [switch]$NoTest
)

$ErrorActionPreference = "Stop"

$Root   = $PSScriptRoot
$PkgDir = Join-Path $Root "lingofuse"
$Rexe   = (Get-Command R.exe -ErrorAction SilentlyContinue).Source
$Rscript = (Get-Command Rscript.exe -ErrorAction SilentlyContinue).Source

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

Write-Section "lingofuse - install"

# ---- Pre-flight --------------------------------------------------------------
if (-not $Rexe -or -not $Rscript) {
    Write-Fail "R.exe or Rscript.exe not found on PATH."
    exit 1
}
Write-Ok ("R.exe: " + $Rexe)

# Resolve the install source.
$sourcePath = $null
if ($Tarball) {
    if (-not (Test-Path $Tarball)) {
        Write-Fail ("Tarball not found: " + $Tarball)
        exit 1
    }
    $sourcePath = (Resolve-Path $Tarball).Path
    Write-Ok ("Source: tarball " + $sourcePath)
} else {
    if (-not (Test-Path $PkgDir)) {
        Write-Fail ("Package directory not found: " + $PkgDir)
        exit 1
    }
    $requiredFiles = @(
        "DESCRIPTION",
        "NAMESPACE",
        "R\api.R",
        "R\zzz.R",
        "src\Makevars",
        "src\Makevars.win"
    )
    $missing = @()
    foreach ($f in $requiredFiles) {
        if (-not (Test-Path (Join-Path $PkgDir $f))) { $missing += $f }
    }
    if ($missing.Count -gt 0) {
        Write-Fail "Package is missing required file(s):"
        foreach ($m in $missing) { Write-Info ("  " + $m) }
        Write-Info ""
        Write-Info "If man\ or NAMESPACE is missing, run:"
        Write-Info "    Rscript -e `"roxygen2::roxygenise('lingofuse')`""
        exit 1
    }
    $sourcePath = (Resolve-Path $PkgDir).Path
    Write-Ok ("Source: source tree " + $sourcePath)
}

# ---- Sanity check on the src\ directory ------------------------------------
if (-not $Tarball) {
    $srcCpp = Join-Path $PkgDir "src\lf_bridge.cpp"
    $srcShim = Join-Path $PkgDir "src\lf_r_shim.c"
    if (-not (Test-Path $srcCpp) -or -not (Test-Path $srcShim)) {
        Write-Warn "lingofuse\src\ is missing one or both of the bridge"
        Write-Warn "source files (lf_bridge.cpp, lf_r_shim.c)."
        Write-Info ""
        Write-Info "These are copied from c_ext\src\ by build_package.ps1."
        Write-Info "Run this first:"
        Write-Info "    .\build_package.ps1 -Rebuild"
        Write-Info ""
        Write-Info "Then re-run install_package.ps1."
        exit 1
    }
}

# ---- R CMD INSTALL -----------------------------------------------------------
Write-Section "Running R CMD INSTALL"

$installArgs = @("CMD", "INSTALL")
if ($Library) {
    if (-not (Test-Path $Library)) {
        New-Item -ItemType Directory -Path $Library -Force | Out-Null
        Write-Info ("Created library directory: " + $Library)
    }
    $installArgs += "--library=$Library"
    Write-Info ("Target library: " + $Library)
} else {
    Write-Info "Target library: R default (typically Program Files\R\...\library)"
    Write-Info "If this fails with 'permission denied', re-run as Administrator"
    Write-Info "or pass -Library to install into a user-writable directory."
}
$installArgs += "--preclean"
$installArgs += $sourcePath

Push-Location $Root
try {
    & $Rexe @installArgs
    $rc = $LASTEXITCODE
} finally {
    Pop-Location
}

if ($rc -ne 0) {
    Write-Fail ("R CMD INSTALL failed (exit code " + $rc + ").")
    exit $rc
}
Write-Ok "Package installed"

# ---- Post-install verification ----------------------------------------------
if ($NoTest) {
    Write-Info "Post-install verification skipped (-NoTest)."
    exit 0
}

Write-Section "Verifying the installed package"

$verifyScript = @'
ok <- TRUE
tryCatch({
    suppressPackageStartupMessages(library(lingofuse))
    cat("  package loaded        :", isNamespaceLoaded("lingofuse"), "\n")
    cat("  lf_load is a function :", is.function(lingofuse::lf_load), "\n")
    cat("  lf_call is a function :", is.function(lingofuse::lf_call), "\n")
    cat("  lf_local_call         :", is.function(lingofuse::lf_local_call), "\n")
    cat("  installed at          :", find.package("lingofuse"), "\n")
}, error = function(e) {
    cat("  ERROR:", conditionMessage(e), "\n")
    ok <<- FALSE
})
if (!ok) quit(status = 1)
'@

$tmp = Join-Path $env:TEMP ("lingofuse_verify_" + [Guid]::NewGuid().ToString("N").Substring(0,8) + ".R")
Set-Content -Path $tmp -Value $verifyScript -Encoding ASCII

$verifyRc = 0
try {
    if ($Library) {
        & $Rscript "-e" ".libPaths('$Library'); source('$($tmp -replace '\\','/')', echo = FALSE)"
    } else {
        & $Rscript "--vanilla" $tmp
    }
    $verifyRc = $LASTEXITCODE
} finally {
    Remove-Item -Force $tmp -ErrorAction SilentlyContinue
}

if ($verifyRc -ne 0) {
    Write-Fail "Post-install verification failed."
    exit 1
}
Write-Ok "Package loads and exports the expected functions"

Write-Section "Done"
Write-Host "  Try it:" -ForegroundColor White
Write-Host "    Rscript -e `"Sys.setenv(LINGOFUSE_RUNTIME='D:/CoreLibrary/LingoFuse/Binary'); library(lingofuse); lf_is_loaded()`"" -ForegroundColor Gray
Write-Host ""

exit 0