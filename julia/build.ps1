# build.ps1 - Build the LingoFuse Julia binding's C shim.
#
# Compiles two shared libraries:
#
#   c_ext/lf_shim_mock.dll        (mock version; Step 1, test_shim.jl)
#   c_ext/real/lf_shim_real.dll   (real version; Step 2+, all runtime use)
#
# Requirements:
#   - MinGW-w64 gcc on PATH, or $env:CC set to a compatible 64-bit
#     C compiler.
#   - The compiler must target x86_64 to produce a DLL that loads into
#     64-bit Julia.

$ErrorActionPreference = "Stop"

$here    = Split-Path -Parent $MyInvocation.MyCommand.Definition
$mockDir = Join-Path $here "c_ext"
$realDir = Join-Path $mockDir "real"

Write-Host "====================================================================" -ForegroundColor Magenta
Write-Host "  LingoFuse Julia Binding - Build" -ForegroundColor Magenta
Write-Host "====================================================================" -ForegroundColor Magenta
Write-Host ""

# --- Check the C compiler -------------------------------------------------

$cc = $env:CC
if (-not $cc) { $cc = "gcc" }

$ccCmd = Get-Command $cc -ErrorAction SilentlyContinue
if (-not $ccCmd) {
    Write-Host "[FAIL] C compiler '$cc' not found on PATH." -ForegroundColor Red
    Write-Host "       Install MinGW-w64, or set `$env:CC to a compatible compiler." -ForegroundColor Yellow
    exit 1
}
Write-Host "[INFO] Compiler : $($ccCmd.Source)" -ForegroundColor Cyan

try {
    $ccVersion = & $cc --version 2>&1 | Select-Object -First 1
    Write-Host "[INFO] Version  : $ccVersion" -ForegroundColor Cyan
} catch {
    Write-Host "[WARN] Could not query the compiler version." -ForegroundColor Yellow
}
Write-Host ""

# --- Build the mock shim (Step 1) ----------------------------------------

Write-Host "[Step 1] Building mock shim (c_ext/build.ps1)..." -ForegroundColor White
Push-Location $mockDir
try {
    & .\build.ps1
    if ($LASTEXITCODE -ne 0) {
        Write-Host "[FAIL] Mock shim build failed (exit $LASTEXITCODE)." -ForegroundColor Red
        exit 1
    }
} finally {
    Pop-Location
}
Write-Host ""

# --- Build the real shim (Step 2+) ---------------------------------------

Write-Host "[Step 2] Building real shim (c_ext/real/build.ps1)..." -ForegroundColor White
Push-Location $realDir
try {
    & .\build.ps1
    if ($LASTEXITCODE -ne 0) {
        Write-Host "[FAIL] Real shim build failed (exit $LASTEXITCODE)." -ForegroundColor Red
        exit 1
    }
} finally {
    Pop-Location
}
Write-Host ""

# --- Summary --------------------------------------------------------------

Write-Host "====================================================================" -ForegroundColor Magenta
Write-Host "  Build complete" -ForegroundColor Green
Write-Host "====================================================================" -ForegroundColor Magenta
Write-Host ""
Write-Host "Artifacts:" -ForegroundColor White
Write-Host "  $mockDir\lf_shim_mock.dll" -ForegroundColor Gray
Write-Host "  $realDir\lf_shim_real.dll" -ForegroundColor Gray
Write-Host ""
Write-Host "Runtime contract:" -ForegroundColor White
Write-Host "  - The real shim loads LingoFuse64.dll lazily via LoadLibraryA." -ForegroundColor Gray
Write-Host "  - Ensure the LingoFuse Binary directory is on PATH, or set" -ForegroundColor Gray
Write-Host "    `$env:LINGOFUSE_LIBRARY to the full DLL path." -ForegroundColor Gray
Write-Host ""