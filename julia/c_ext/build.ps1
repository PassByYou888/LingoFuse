# build.ps1 - Compile the C shim and the mock LingoFuse implementation
# into a single DLL on Windows using MinGW-w64's gcc.
#
# Requirements:
#   - MinGW-w64 (gcc.exe on PATH, or set $env:CC before running).
#   - A 64-bit toolchain matching the Julia build (x86_64-w64-mingw32-gcc).

$ErrorActionPreference = "Stop"

$here = Split-Path -Parent $MyInvocation.MyCommand.Definition
Set-Location $here

$cc = $env:CC
if (-not $cc) { $cc = "gcc" }

$out = "lf_shim_mock.dll"

Write-Host "==> Compiling $out"
& $cc -shared -O2 -Wall -Wextra -std=c99 `
    -o $out `
    lf_shim.c mock_lf.c

if ($LASTEXITCODE -ne 0) {
    throw "Compilation failed with exit code $LASTEXITCODE"
}

Write-Host "==> Done: $here\$out"