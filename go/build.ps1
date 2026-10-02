# =============================================================================
#  build.ps1 — build every Go package and the cross-demo executables
# -----------------------------------------------------------------------------
#  Steps:
#    1. go build ./...             compile every package
#    2. go vet ./...               static checks (skip with -SkipVet)
#    3. go build -o bin\...        three cross executables into go\bin\
#    4. copy LingoFuse64.dll       from ..\Binary\ into go\bin\
#
#  Usage:
#    .\build.ps1
#    .\build.ps1 -SkipVet
#
#  Exit code is non-zero when any step fails.
# =============================================================================

[CmdletBinding()]
param(
    [switch]$SkipVet
)

$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot

Push-Location $root
try {
    # -------------------------------------------------------------------------
    # 1. Compile every package
    # -------------------------------------------------------------------------
    Write-Host "=== go build ./... ===" -ForegroundColor Cyan
    go build ./...
    if ($LASTEXITCODE -ne 0) { throw "go build failed" }

    # -------------------------------------------------------------------------
    # 2. Static checks (optional)
    # -------------------------------------------------------------------------
    if (-not $SkipVet) {
        Write-Host "=== go vet ./... ===" -ForegroundColor Cyan
        go vet ./...
        if ($LASTEXITCODE -ne 0) { throw "go vet failed" }
    }

    # -------------------------------------------------------------------------
    # 3. Build the three cross-demo executables into go\bin\
    # -------------------------------------------------------------------------
    $binDir = Join-Path $root 'bin'
    New-Item -ItemType Directory -Force -Path $binDir | Out-Null

    $targets = @(
        @{ Name = 'cross-service'; Pkg = './cross/cross-service' },
        @{ Name = 'cross-node';    Pkg = './cross/cross-node'    },
        @{ Name = 'cross-call';    Pkg = './cross/cross-call'    }
    )

    foreach ($t in $targets) {
        $out = Join-Path $binDir "$($t.Name).exe"
        Write-Host "=== go build -o $out $($t.Pkg) ===" -ForegroundColor Cyan
        go build -o $out $t.Pkg
        if ($LASTEXITCODE -ne 0) { throw "$($t.Name) build failed" }
    }

    # -------------------------------------------------------------------------
    # 4. Copy the native runtime next to the cross executables
    # -------------------------------------------------------------------------
    $dllSrc = Join-Path $root '..\Binary\LingoFuse64.dll'
    if (Test-Path $dllSrc) {
        Copy-Item -Force $dllSrc $binDir
        Write-Host "Copied LingoFuse64.dll to $binDir"
    } else {
        Write-Host "Warning: $dllSrc not found." -ForegroundColor Yellow
        Write-Host "         Copy LingoFuse64.dll into $binDir manually." -ForegroundColor Yellow
    }

    Write-Host ""
    Write-Host "Build succeeded. Output: $binDir" -ForegroundColor Green
}
finally {
    Pop-Location
}