# build.ps1 - Compile the real LingoFuse shim on Windows.
#
# Links:
#     ../lf_shim.c        (the C trampoline + event queue)
#     lf_real_link.c      (runtime resolver for the real LingoFuse DLL)
#
# into lf_shim_real.dll. The real LingoFuse library is NOT linked at
# build time; it is loaded at runtime by lf_real_link.c via
# LoadLibraryA + GetProcAddress.
#
# Requirements:
#   - MinGW-w64 gcc (or set $env:CC to a compatible 64-bit C compiler).
#   - A 64-bit toolchain matching the Julia build.

$ErrorActionPreference = "Stop"

$here    = Split-Path -Parent $MyInvocation.MyCommand.Definition
$cExtDir = Split-Path -Parent $here

Set-Location $here

$cc = $env:CC
if (-not $cc) { $cc = "gcc" }

$out = "lf_shim_real.dll"

$shimSrc = Join-Path $cExtDir "lf_shim.c"
if (-not (Test-Path $shimSrc -PathType Leaf)) {
    throw "Cannot find shim source: $shimSrc"
}

$resolverSrc = Join-Path $here "lf_real_link.c"
if (-not (Test-Path $resolverSrc -PathType Leaf)) {
    throw "Cannot find resolver source: $resolverSrc"
}

Write-Host "==> Compiling $out"
Write-Host "    lf_shim.c        (from $cExtDir)"
Write-Host "    lf_real_link.c   (from $here)"

& $cc -shared -O2 -Wall -Wextra -std=c99 `
    -o $out `
    $shimSrc $resolverSrc

if ($LASTEXITCODE -ne 0) {
    throw "Compilation failed with exit code $LASTEXITCODE"
}

Write-Host "==> Done: $here\$out"
Write-Host ""
Write-Host "Runtime contract:"
Write-Host "  The shim loads LingoFuse64.dll at first use. Before running a"
Write-Host "  Julia program that uses this shim, ensure either:"
Write-Host ""
Write-Host "    (a) the LingoFuse Binary directory is on PATH, or"
Write-Host "    (b) LINGOFUSE_LIBRARY points to the full DLL path."
Write-Host ""
Write-Host '  Example (current session only):'
Write-Host '      $env:LINGOFUSE_LIBRARY = "D:\CoreLibrary\LingoFuse\Binary\LingoFuse64.dll"'
Write-Host ""
Write-Host "  The Julia loader (julia/src/loader.jl) performs this setup"
Write-Host "  automatically when it locates the runtime."