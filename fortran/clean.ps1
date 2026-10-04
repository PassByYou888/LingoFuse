<#
.SYNOPSIS
    Remove all build artifacts produced by the Fortran bridge and the
    cross-language demo.

.DESCRIPTION
    Invokes `mingw32-make clean` in c_ext and (if present) cross_demo,
    then performs a secondary sweep for any leftover *.o / *.mod /
    *.exe files in either directory.

    Runtime DLLs are never touched by this script.
#>

[CmdletBinding()]
param()

$ErrorActionPreference = 'Continue'

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path

$dirs = @(
    (Join-Path $ScriptDir 'c_ext'),
    (Join-Path $ScriptDir 'cross_demo')
)

$MakeExe = $null
foreach ($candidate in @('mingw32-make', 'make')) {
    $found = Get-Command -Name $candidate -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($found) {
        $MakeExe = [string]$found.Source
        break
    }
}

Write-Host ''
Write-Host '======================================================================' -ForegroundColor Cyan
Write-Host '  LingoFuse Fortran bridge - clean' -ForegroundColor Cyan
Write-Host '======================================================================' -ForegroundColor Cyan
if ($MakeExe) {
    Write-Host ("  Make tool : {0}" -f $MakeExe)
}
else {
    Write-Host '  Make tool : (not found; falling back to direct deletion)' -ForegroundColor Yellow
}
Write-Host ''

foreach ($d in $dirs) {
    if (-not (Test-Path -LiteralPath $d)) {
        continue
    }

    Write-Host ('--- {0} ---' -f (Split-Path -Leaf $d)) -ForegroundColor Yellow

    if ($MakeExe -and (Test-Path -LiteralPath (Join-Path $d 'Makefile'))) {
        & $MakeExe -C $d clean
        if ($LASTEXITCODE -ne 0) {
            Write-Host ("  (make clean exited with {0}; continuing with secondary sweep)" -f $LASTEXITCODE) -ForegroundColor Yellow
        }
    }

    $removedCount = 0
    foreach ($pat in @('*.o', '*.mod', '*.exe')) {
        $files = Get-ChildItem -LiteralPath $d -File -Filter $pat -ErrorAction SilentlyContinue
        foreach ($f in $files) {
            Write-Host ("  rm {0}" -f $f.Name)
            Remove-Item -LiteralPath $f.FullName -Force -ErrorAction SilentlyContinue
            $removedCount++
        }
    }

    if ($removedCount -eq 0) {
        Write-Host '  (nothing left to remove)'
    }
    Write-Host ''
}

Write-Host '[OK] Clean completed.' -ForegroundColor Green
Write-Host ''
exit 0