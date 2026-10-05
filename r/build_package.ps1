<#
.SYNOPSIS
    Build and install the lingofuse R package.

.DESCRIPTION
    1. Copies the current bridge source files from c_ext\src\ into the
       package's src\ directory.
    2. Runs R CMD INSTALL on the lingofuse package.
    3. Runs a post-install verification script with Rscript.exe.

    The source files are copied (not symlinked) because R CMD INSTALL
    expects a self-contained src\ directory. The c_ext\src\ tree
    remains the single source of truth; this script is the only place
    that copies it.

    Re-run this script after every change to c_ext\src\*.{c,h,cpp,hpp}.

.PARAMETER Rebuild
    Delete the package's src\*.o / *.dll / *.so artifacts before
    building, forcing a full recompile.
#>

[CmdletBinding()]
param([switch]$Rebuild)

$ErrorActionPreference = "Stop"

$Root        = $PSScriptRoot
$SourceDir   = Join-Path $Root "c_ext\src"
$PkgDir      = Join-Path $Root "lingofuse"
$PkgSrcDir   = Join-Path $PkgDir "src"

$SourceFiles = @(
    "lf_r_shim.c",
    "lf_r_shim.h",
    "lf_bridge.cpp",
    "lf_loader.h"
)

function Write-Section { param([string]$T)
    Write-Host ""
    Write-Host ("=" * 72) -ForegroundColor Cyan
    Write-Host $T -ForegroundColor Cyan
    Write-Host ("=" * 72) -ForegroundColor Cyan
}
function Write-Ok   { param([string]$T) Write-Host ("[OK]   " + $T) -ForegroundColor Green }
function Write-Info { param([string]$T) Write-Host ("       " + $T) -ForegroundColor Gray }
function Write-Fail { param([string]$T) Write-Host ("[FAIL] " + $T) -ForegroundColor Red }

Write-Section "lingofuse R package - build"

# ---- Pre-flight --------------------------------------------------------------
$rExe = Get-Command R.exe -ErrorAction SilentlyContinue
if (-not $rExe) {
    Write-Fail "R.exe not found on PATH."
    exit 1
}
Write-Ok ("R.exe: " + $rExe.Source)

$rscriptExe = Get-Command Rscript.exe -ErrorAction SilentlyContinue
if (-not $rscriptExe) {
    Write-Fail "Rscript.exe not found on PATH."
    exit 1
}
Write-Ok ("Rscript.exe: " + $rscriptExe.Source)

if (-not (Test-Path $PkgDir)) {
    Write-Fail ("Package directory not found: " + $PkgDir)
    Write-Info "Create it and populate DESCRIPTION, NAMESPACE, R\, etc."
    exit 1
}
foreach ($f in @("DESCRIPTION", "NAMESPACE", "R\api.R", "R\zzz.R")) {
    $p = Join-Path $PkgDir $f
    if (-not (Test-Path $p)) {
        Write-Fail ("Missing package file: " + $f)
        exit 1
    }
}
Write-Ok "Package skeleton is present"

# ---- Copy sources ------------------------------------------------------------
Write-Section "Copying bridge sources into lingofuse\src\"

if (-not (Test-Path $PkgSrcDir)) {
    New-Item -ItemType Directory -Path $PkgSrcDir -Force | Out-Null
    Write-Info ("Created: " + $PkgSrcDir)
}

if ($Rebuild) {
    Get-ChildItem -Path $PkgSrcDir -Include "*.o","*.obj","*.so","*.dll" `
        -File -ErrorAction SilentlyContinue |
        ForEach-Object { Remove-Item -Force $_.FullName; Write-Info ("removed " + $_.Name) }
}

foreach ($f in $SourceFiles) {
    $src = Join-Path $SourceDir $f
    if (-not (Test-Path $src)) {
        Write-Fail ("Missing source: " + $src)
        exit 1
    }
    Copy-Item -Force $src (Join-Path $PkgSrcDir $f)
    Write-Ok ("copied " + $f)
}

# Makevars / Makevars.win are part of the package, not copied from c_ext.
foreach ($mk in @("Makevars", "Makevars.win")) {
    $p = Join-Path $PkgSrcDir $mk
    if (-not (Test-Path $p)) {
        Write-Fail ("Missing package file: src\" + $mk)
        exit 1
    }
}

# ---- R CMD INSTALL -----------------------------------------------------------
Write-Section "Running R CMD INSTALL"

Push-Location $Root
try {
    & $rExe.Source CMD INSTALL --preclean $PkgDir
    $rc = $LASTEXITCODE
} finally {
    Pop-Location
}

if ($rc -ne 0) {
    Write-Fail ("R CMD INSTALL failed (exit code " + $rc + ").")
    exit $rc
}

Write-Ok "lingofuse installed"

# ---- Verification ------------------------------------------------------------
# This block runs a small R script with Rscript.exe (NOT R.exe --vanilla,
# which would start an interactive console and ignore the script file).
Write-Section "Verifying the installed package"

$verifyScript = @'
ok <- TRUE
tryCatch({
    suppressPackageStartupMessages(library(lingofuse))
    cat("  package loaded:", isNamespaceLoaded("lingofuse"), "\n")
    cat("  lf_load is a function:", is.function(lingofuse::lf_load), "\n")
    cat("  lf_call is a function:", is.function(lingofuse::lf_call), "\n")

    # Confirm the DLL is loadable from the installed package.
    lib_dir <- system.file("libs", package = "lingofuse")
    cat("  package libs dir:", lib_dir, "\n")
}, error = function(e) {
    cat("  ERROR:", conditionMessage(e), "\n")
    ok <<- FALSE
})
if (!ok) quit(status = 1)
'@

$tmp = Join-Path $env:TEMP "lingofuse_verify.R"
Set-Content -Path $tmp -Value $verifyScript -Encoding ASCII

& $rscriptExe.Source "--vanilla" $tmp
$verifyRc = $LASTEXITCODE
Remove-Item -Force $tmp -ErrorAction SilentlyContinue

if ($verifyRc -ne 0) {
    Write-Fail "Post-install verification failed."
    exit 1
}
Write-Ok "Package loads and exports the expected functions"

Write-Section "Build Summary"
Write-Host "  Package : lingofuse"
Write-Host "  Source  : " + $PkgSrcDir
Write-Host ""
Write-Host "Try it:" -ForegroundColor White
Write-Host "  Rscript -e `"library(lingofuse); lf_load('D:/CoreLibrary/LingoFuse/Binary'); lf_is_loaded()`"" -ForegroundColor Gray
Write-Host ""

exit 0