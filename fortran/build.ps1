<#
.SYNOPSIS
    Build the LingoFuse Fortran bridge, its test programs, and the
    cross-language demo.

.DESCRIPTION
    Thin wrapper around mingw32-make. Two build directories are
    supported:

        c_ext        - the bridge, the C test, and the Fortran tests
        cross_demo   - the cross-language demo programs

    Use -Target to select which one to build. The default is "all",
    which builds both in order (c_ext first, then cross_demo, because
    cross_demo links against objects produced by c_ext).

    Runtime DLLs are not handled by this script. The C++ bridge
    (LingoFuse.c / LF_LoadLibrary) resolves the LingoFuse runtime
    through the standard OS loader search order: the directory that
    contains the current executable, then the system PATH. Place
    LingoFuse64.dll (or the platform equivalent) wherever your
    environment already expects it.

.PARAMETER Target
    Which directory to build. One of: all, c_ext, cross_demo.
    Default: all.

.PARAMETER MakeArgs
    Extra arguments passed through to make.

.EXAMPLE
    .\build.ps1
    Build c_ext and cross_demo.

.EXAMPLE
    .\build.ps1 -Target cross_demo -MakeArgs '-j4'
    Build only the demo with four parallel jobs.
#>

[CmdletBinding()]
param(
    [ValidateSet('all', 'c_ext', 'cross_demo')]
    [string]$Target = 'all',
    [string[]]$MakeArgs = @()
)

$ErrorActionPreference = 'Continue'

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path

# ---------------------------------------------------------------------------
# Locate mingw32-make (fall back to make).
# ---------------------------------------------------------------------------

$MakeExe = $null
foreach ($candidate in @('mingw32-make', 'make')) {
    $found = Get-Command -Name $candidate -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($found) {
        $MakeExe = [string]$found.Source
        break
    }
}

if (-not $MakeExe) {
    Write-Host '[FATAL] Neither mingw32-make nor make was found on PATH.' -ForegroundColor Red
    Write-Host '        Install MinGW-w64 or MSYS2, then add its bin directory to PATH.'
    exit 3
}

# ---------------------------------------------------------------------------
# Determine which directories to build.
# ---------------------------------------------------------------------------

$dirs = @()
switch ($Target) {
    'all'        { $dirs = @('c_ext', 'cross_demo') }
    'c_ext'      { $dirs = @('c_ext') }
    'cross_demo' { $dirs = @('cross_demo') }
}

foreach ($d in $dirs) {
    $full = Join-Path $ScriptDir $d
    if (-not (Test-Path -LiteralPath $full)) {
        Write-Host ("[FATAL] directory not found: {0}" -f $full) -ForegroundColor Red
        exit 2
    }
    if (-not (Test-Path -LiteralPath (Join-Path $full 'Makefile'))) {
        Write-Host ("[FATAL] Makefile not found in: {0}" -f $full) -ForegroundColor Red
        exit 2
    }
}

# ---------------------------------------------------------------------------
# Banner
# ---------------------------------------------------------------------------

Write-Host ''
Write-Host '======================================================================' -ForegroundColor Cyan
Write-Host '  LingoFuse Fortran bridge - build' -ForegroundColor Cyan
Write-Host '======================================================================' -ForegroundColor Cyan
Write-Host ("  Script dir : {0}" -f $ScriptDir)
Write-Host ("  Target     : {0}" -f $Target)
Write-Host ("  Make tool  : {0}" -f $MakeExe)
Write-Host ''

# ---------------------------------------------------------------------------
# Run make for each target directory.
# ---------------------------------------------------------------------------

$exitCode = 0

foreach ($d in $dirs) {
    $full = Join-Path $ScriptDir $d
    $cmd  = @('-C', $full) + $MakeArgs

    Write-Host ('--- make ({0}) ---' -f $d) -ForegroundColor Yellow
    Write-Host ("  {0} {1}" -f (Split-Path -Leaf $MakeExe), ($cmd -join ' ')) -ForegroundColor DarkGray
    Write-Host ''

    & $MakeExe @cmd
    if ($LASTEXITCODE -ne 0) {
        Write-Host ("[ERROR] make in {0} failed (exit {1})." -f $d, $LASTEXITCODE) -ForegroundColor Red
        $exitCode = $LASTEXITCODE
        break
    }
    Write-Host ''
}

# ---------------------------------------------------------------------------
# Final verdict
# ---------------------------------------------------------------------------

if ($exitCode -eq 0) {
    Write-Host '[OK] Build completed.' -ForegroundColor Green
    Write-Host ''
}
else {
    Write-Host '[ERROR] Build failed.' -ForegroundColor Red
    Write-Host ''
}

exit $exitCode