# =============================================================================
#  build.ps1 — build every Go package and the cross-demo executables
# -----------------------------------------------------------------------------
#  Steps:
#    1. (optional) go clean -cache        when -Clean is passed
#    2. go build ./...                    compile every package
#    3. go vet ./...                      static checks (skip with -SkipVet)
#    4. go build -o bin\...               three cross executables into go\bin\
#    5. copy LingoFuse64.dll              from ..\Binary\ into go\bin\
#
#  The three cross-demo executables mirror the C++ / C# / Pascal / Rust
#  / JavaScript demos byte-for-byte on the wire:
#
#      cross-service   coordinator for endpoint ipc:cross
#      cross-node      worker exposing App "demo" with add / inv_seri
#      cross-call      load tester (32 goroutines, 10 seconds)
#
#  Usage:
#    .\build.ps1
#    .\build.ps1 -SkipVet
#    .\build.ps1 -Clean
#    .\build.ps1 -Clean -SkipVet
#
#  Exit code is non-zero when any step fails.
# =============================================================================

[CmdletBinding()]
param(
    [switch]$SkipVet,
    [switch]$Clean
)

$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot

Push-Location $root
try {
    # -------------------------------------------------------------------------
    # 0. Optional cache clean
    # -------------------------------------------------------------------------
    if ($Clean) {
        Write-Host "=== go clean -cache ===" -ForegroundColor Cyan
        go clean -cache
        if ($LASTEXITCODE -ne 0) { throw "go clean -cache failed" }
    }

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
    #
    #    The Go loader looks for LingoFuse64.dll in the executable's
    #    directory first, then on the system loader search path. Placing
    #    a copy next to the cross binaries makes them runnable without
    #    any PATH modification.
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