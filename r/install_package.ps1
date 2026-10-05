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

    Before installing, this script regenerates roxygen2 output
    (NAMESPACE and man/*.Rd) whenever either is missing, so that the
    installed package always has its documentation. Set -NoRoxygen to
    skip that step.

    By default the package is installed into a USER library, so that no
    Administrator privileges are required. Pass -Library to target a
    different library directory, or -SystemLibrary to target R's system
    library (requires Administrator privileges).

    Post-install, the script loads the package in a fresh R process to
    verify that it can be attached and that the expected functions are
    present. Pass -NoTest to skip this step.

.PARAMETER Tarball
    Path to a lingofuse_<ver>.tar.gz. When specified, the script installs
    that tarball and ignores the source tree.

.PARAMETER Library
    Install into this library directory instead of the default user
    library.

.PARAMETER SystemLibrary
    Install into R's system library. Requires Administrator privileges.
    Mutually exclusive with -Library.

.PARAMETER NoTest
    Skip the post-install verification step.

.PARAMETER NoRoxygen
    Skip the automatic roxygen2 regeneration step. Use this when
    roxygen2 is not installed and the package's NAMESPACE and man/
    directory are already up to date.

.EXAMPLE
    .\install_package.ps1

.EXAMPLE
    .\install_package.ps1 -Library "$env:USERPROFILE\R\win-library\4.6"

.EXAMPLE
    .\install_package.ps1 -SystemLibrary

.EXAMPLE
    .\install_package.ps1 -Tarball .\_check_20261005_222457\lingofuse_0.5.0.tar.gz
#>

[CmdletBinding()]
param(
    [string]$Tarball,
    [string]$Library,
    [switch]$SystemLibrary,
    [switch]$NoTest,
    [switch]$NoRoxygen
)

$ErrorActionPreference = "Stop"

$Root    = $PSScriptRoot
$PkgDir  = Join-Path $Root "lingofuse"
$Rexe    = (Get-Command R.exe      -ErrorAction SilentlyContinue).Source
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

if ($Library -and $SystemLibrary) {
    Write-Fail "-Library and -SystemLibrary are mutually exclusive."
    exit 1
}

# ---- Resolve the install source ---------------------------------------------
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
        "R\api.R",
        "R\zzz.R",
        "src\Makevars",
        "src\Makevars.win",
        "src\lf_bridge.cpp",
        "src\lf_r_shim.c",
        "src\lf_r_shim.h",
        "src\lf_loader.h"
    )
    $missing = @()
    foreach ($f in $requiredFiles) {
        if (-not (Test-Path (Join-Path $PkgDir $f))) { $missing += $f }
    }
    if ($missing.Count -gt 0) {
        Write-Fail "Package is missing required file(s):"
        foreach ($m in $missing) { Write-Info ("  " + $m) }
        Write-Info ""
        Write-Info "If src\lf_*.{c,h,cpp} is missing, run:"
        Write-Info "    .\build_package.ps1 -Rebuild"
        exit 1
    }
    $sourcePath = (Resolve-Path $PkgDir).Path
    Write-Ok ("Source: source tree " + $sourcePath)
}

# ---- Roxygen2 regeneration (only when installing from the source tree) -------
if (-not $Tarball -and -not $NoRoxygen) {
    $nsPath = Join-Path $PkgDir "NAMESPACE"
    $manDir = Join-Path $PkgDir "man"

    $manEmpty = $true
    if (Test-Path $manDir) {
        $manFiles = @(Get-ChildItem -Path $manDir -Filter "*.Rd" -File -ErrorAction SilentlyContinue)
        if ($manFiles.Count -gt 0) { $manEmpty = $false }
    }

    if (-not (Test-Path $nsPath) -or $manEmpty) {
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
            Write-Warn "roxygenise failed; continuing without regenerating."
            Write-Warn "The installed package may have missing documentation."
            Write-Warn "Install roxygen2 with:"
            Write-Warn "    Rscript -e `"install.packages('roxygen2')`""
            Write-Warn "Then re-run install_package.ps1."
            Write-Warn ""
            Write-Warn "To silence this warning when you know the package's"
            Write-Warn "NAMESPACE and man\ are already up to date, use:"
            Write-Warn "    .\install_package.ps1 -NoRoxygen"
        } else {
            Write-Ok "roxygen2 output regenerated."
        }
    } else {
        $manCount = @(Get-ChildItem -Path $manDir -Filter "*.Rd" -File).Count
        Write-Info ("Roxygen2 output present (NAMESPACE + " + $manCount + " .Rd file(s)).")
    }
}

# ---- Determine the target library -------------------------------------------
$targetLibrary = $null
if ($Library) {
    $targetLibrary = $Library
    if (-not (Test-Path $targetLibrary)) {
        New-Item -ItemType Directory -Path $targetLibrary -Force | Out-Null
        Write-Info ("Created library directory: " + $targetLibrary)
    }
    Write-Info ("Target library: " + $targetLibrary)
} elseif ($SystemLibrary) {
    Write-Info "Target library: R system library (requires Administrator)"
} else {
    # Default: the first user-writable library on .libPaths().
    $detected = (& $Rscript "-e" "cat(.libPaths()[1])") -join ""
    $detected = $detected.Trim()
    if ($detected) {
        $targetLibrary = $detected
        if (-not (Test-Path $targetLibrary)) {
            New-Item -ItemType Directory -Path $targetLibrary -Force | Out-Null
        }
        Write-Info ("Target library: " + $targetLibrary + " (user library)")
    } else {
        Write-Info "Target library: R default (could not detect a user library)"
    }
}

# ---- R CMD INSTALL -----------------------------------------------------------
Write-Section "Running R CMD INSTALL"

$installArgs = @("CMD", "INSTALL")
if ($targetLibrary) {
    $installArgs += "--library=$targetLibrary"
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
    cat("  lf_find_runtime       :", is.function(lingofuse::lf_find_runtime), "\n")
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
    if ($targetLibrary) {
        & $Rscript "-e" ".libPaths('$targetLibrary'); source('$($tmp -replace '\\','/')', echo = FALSE)"
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
Write-Host "  Try it (runtime directory is resolved without a hard-coded path):" -ForegroundColor White
Write-Host "    `$env:LINGOFUSE_RUNTIME = '<runtime_dir>'" -ForegroundColor Gray
Write-Host "    Rscript -e `"library(lingofuse); lf_is_loaded()`"" -ForegroundColor Gray
Write-Host ""
Write-Host "  Or, if the runtime is at <repo>/Binary/:" -ForegroundColor White
Write-Host "    Rscript -e `"library(lingofuse); lf_load('Binary'); lf_is_loaded()`"" -ForegroundColor Gray
Write-Host ""

exit 0