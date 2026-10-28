[CmdletBinding()]
param(
    [switch]$Clean,
    [switch]$SkipCheck
)

$ErrorActionPreference = "Stop"

function Write-Info { param([string]$m) Write-Host "[INFO] $m" -ForegroundColor Cyan }
function Write-Ok   { param([string]$m) Write-Host "[ OK ] $m" -ForegroundColor Green }
function Write-Warn { param([string]$m) Write-Host "[WARN] $m" -ForegroundColor Yellow }
function Write-Err  { param([string]$m) Write-Host "[FAIL] $m" -ForegroundColor Red }

try {
    Write-Info "Build lingofuse-ts"
    $root = $PSScriptRoot

    if (-not (Get-Command npm  -ErrorAction SilentlyContinue)) { throw "npm is not on PATH." }
    if (-not (Get-Command node -ErrorAction SilentlyContinue)) { throw "node is not on PATH." }

    $nodeVersion = (& node -v 2>$null).Trim()
    Write-Info "  Node.js : $nodeVersion"

    Push-Location -LiteralPath $root
    try {
        if (-not (Test-Path -LiteralPath (Join-Path $root "node_modules"))) {
            Write-Warn "  node_modules is missing; running 'npm install' ..."
            $out = & npm install 2>&1
            if ($LASTEXITCODE -ne 0) { throw "npm install failed:`n$out" }
            Write-Ok "  npm install done."
        }

        if ($Clean) {
            Write-Info "  Cleaning dist/ ..."
            $out = & npm run clean 2>&1
            if ($LASTEXITCODE -ne 0) { throw "npm run clean failed:`n$out" }
            Write-Ok "  Clean done."
        }

        if (-not $SkipCheck) {
            Write-Info "  Running type check (tsc --noEmit) ..."
            $out = & npm run check 2>&1
            if ($LASTEXITCODE -ne 0) {
                Write-Err "  Type check failed:"
                $out | ForEach-Object { Write-Host "    $_" }
                throw "npm run check failed."
            }
            Write-Ok "  Type check passed."
        }

        Write-Info "  Compiling (tsc -p tsconfig.build.json) ..."
        $out = & npm run build 2>&1
        if ($LASTEXITCODE -ne 0) {
            Write-Err "  Compilation failed:"
            $out | ForEach-Object { Write-Host "    $_" }
            throw "npm run build failed."
        }
        Write-Ok "  Compilation done."

        $distIndex = Join-Path $root "dist/index.js"
        $distTypes = Join-Path $root "dist/index.d.ts"
        if (-not (Test-Path -LiteralPath $distIndex)) { throw "dist/index.js is missing after build." }
        if (-not (Test-Path -LiteralPath $distTypes)) { throw "dist/index.d.ts is missing after build." }
        Write-Ok "  dist/index.js and dist/index.d.ts exist."

        $jsCount  = (Get-ChildItem -LiteralPath (Join-Path $root "dist") -Filter "*.js").Count
        $dtsCount = (Get-ChildItem -LiteralPath (Join-Path $root "dist") -Filter "*.d.ts").Count
        Write-Info "  dist/*.js count  : $jsCount"
        Write-Info "  dist/*.d.ts count: $dtsCount"

        Write-Ok "Build completed."
        exit 0
    } finally {
        Pop-Location
    }
} catch {
    Write-Err $_.Exception.Message
    exit 1
}