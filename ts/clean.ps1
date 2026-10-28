[CmdletBinding()]
param(
    [switch]$IncludeNodeModules,
    [switch]$IncludeCache
)

$ErrorActionPreference = "Stop"

function Write-Info { param([string]$m) Write-Host "[INFO] $m" -ForegroundColor Cyan }
function Write-Ok   { param([string]$m) Write-Host "[ OK ] $m" -ForegroundColor Green }
function Write-Warn { param([string]$m) Write-Host "[WARN] $m" -ForegroundColor Yellow }
function Write-Err  { param([string]$m) Write-Host "[FAIL] $m" -ForegroundColor Red }

try {
    Write-Info "Clean lingofuse-ts"
    $root = $PSScriptRoot

    $distDir = Join-Path $root "dist"
    if (Test-Path -LiteralPath $distDir) {
        Remove-Item -LiteralPath $distDir -Recurse -Force
        Write-Ok "  Removed: dist/"
    } else {
        Write-Info "  dist/ not present"
    }

    foreach ($f in @("tsconfig.build.tsbuildinfo", "tsconfig.tsbuildinfo")) {
        $p = Join-Path $root $f
        if (Test-Path -LiteralPath $p) {
            Remove-Item -LiteralPath $p -Force
            Write-Ok "  Removed: $f"
        }
    }

    if ($IncludeCache) {
        $cacheDir = Join-Path $root ".cache"
        if (Test-Path -LiteralPath $cacheDir) {
            Remove-Item -LiteralPath $cacheDir -Recurse -Force
            Write-Ok "  Removed: .cache/"
        }
    }

    if ($IncludeNodeModules) {
        $nmDir = Join-Path $root "node_modules"
        if (Test-Path -LiteralPath $nmDir) {
            Remove-Item -LiteralPath $nmDir -Recurse -Force
            Write-Ok "  Removed: node_modules/"
        }
        $pkgLock = Join-Path $root "package-lock.json"
        if (Test-Path -LiteralPath $pkgLock) {
            Remove-Item -LiteralPath $pkgLock -Force
            Write-Ok "  Removed: package-lock.json"
        }
    }

    Write-Ok "Clean completed."
    exit 0
} catch {
    Write-Err $_.Exception.Message
    exit 1
}