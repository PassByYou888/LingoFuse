[CmdletBinding()]
param()

$ErrorActionPreference = "Continue"

function Write-Section {
    param([string]$m)
    Write-Host ""
    Write-Host ("=" * 72) -ForegroundColor DarkGray
    Write-Host $m -ForegroundColor White
    Write-Host ("=" * 72) -ForegroundColor DarkGray
}
function Write-Info { param([string]$m) Write-Host "         $m" -ForegroundColor DarkGray }
function Write-Ok   { param([string]$m) Write-Host "  [OK]   $m" -ForegroundColor Green }
function Write-Warn { param([string]$m) Write-Host "  [WARN] $m" -ForegroundColor Yellow }
function Write-Err  { param([string]$m) Write-Host "  [FAIL] $m" -ForegroundColor Red }

$script:failures = 0
$script:warnings = 0

function Test-Pass { param([string]$m) Write-Ok $m }
function Test-Fail { param([string]$m) Write-Err $m; $script:failures += 1 }
function Test-Warn { param([string]$m) Write-Warn $m; $script:warnings += 1 }

$root = $PSScriptRoot
$isWin = ($env:OS -eq "Windows_NT")

Write-Section "1. PowerShell"
Write-Info "Version   : $($PSVersionTable.PSVersion)"
Write-Info "Edition   : $($PSVersionTable.PSEdition)"
Write-Info "Platform  : $(if ($isWin) { 'Windows' } else { 'Unix' })"
if ($PSVersionTable.PSVersion.Major -ge 5) {
    Test-Pass "PowerShell $($PSVersionTable.PSVersion) is supported."
} else {
    Test-Fail "PowerShell 5.1 or later is required."
}

Write-Section "2. Node.js"
$nodeCmd = Get-Command node -ErrorAction SilentlyContinue
if ($null -eq $nodeCmd) {
    Test-Fail "node is not on PATH."
} else {
    $nodeVersion = (& node -v 2>$null).Trim()
    $nodeArch    = (& node -p "process.arch" 2>$null).Trim()
    $nodePlatform = (& node -p "process.platform" 2>$null).Trim()
    Write-Info "Version   : $nodeVersion"
    Write-Info "Arch      : $nodeArch"
    Write-Info "Platform  : $nodePlatform"
    Write-Info "Executable: $($nodeCmd.Source)"
    try {
        $major = [int]($nodeVersion.TrimStart('v').Split('.')[0])
        if ($major -ge 18) {
            Test-Pass "Node.js $nodeVersion is supported (>= 18)."
        } else {
            Test-Fail "Node.js >= 18 required, found $nodeVersion."
        }
    } catch {
        Test-Warn "Could not parse Node version: $nodeVersion"
    }
}

Write-Section "3. npm"
$npmCmd = Get-Command npm -ErrorAction SilentlyContinue
if ($null -eq $npmCmd) {
    Test-Fail "npm is not on PATH."
} else {
    $npmVersion = (& npm --version 2>$null).Trim()
    Write-Info "Version   : $npmVersion"
    Test-Pass "npm $npmVersion is available."
}

Write-Section "4. Project structure"
$requiredFiles = @(
    "package.json",
    "tsconfig.json",
    "tsconfig.build.json",
    "src/index.ts",
    "src/binding.ts",
    "src/data-handle.ts",
    "src/app-handle.ts",
    "src/lf-io.ts",
    "src/errors.ts",
    "src/framework.ts",
    "src/address.ts",
    "src/async-support.ts",
    "src/options.ts",
    "src/status.ts",
    "src/network-events.ts",
    "src/p2p-registration.ts",
    "src/runtime.ts",
    "src/types.ts",
    "test/test.ts",
    "test/test-v2.ts",
    "examples/hello-world.ts",
    "cross/cross-service.ts",
    "cross/cross-node.ts",
    "cross/cross-call.ts"
)
$missing = 0
foreach ($f in $requiredFiles) {
    if (-not (Test-Path -LiteralPath (Join-Path $root $f))) {
        Test-Fail "Missing: $f"
        $missing += 1
    }
}
if ($missing -eq 0) {
    Test-Pass "All $($requiredFiles.Count) required files are present."
}

Write-Section "5. node_modules"
$nmDir = Join-Path $root "node_modules"
if (-not (Test-Path -LiteralPath $nmDir)) {
    Test-Fail "node_modules is missing. Run: npm install"
} else {
    Test-Pass "node_modules exists."
    foreach ($p in @("koffi", "typescript", "tsx", "@types/node")) {
        $pkgPath = Join-Path $nmDir $p
        if (Test-Path -LiteralPath $pkgPath) {
            $ver = "(unknown)"
            $pkgJson = Join-Path $pkgPath "package.json"
            if (Test-Path -LiteralPath $pkgJson) {
                try {
                    $obj = Get-Content -LiteralPath $pkgJson -Raw -Encoding UTF8 | ConvertFrom-Json
                    if ($obj.version) { $ver = $obj.version }
                } catch { }
            }
            Test-Pass "  $p ($ver)"
        } else {
            Test-Fail "  $p is not installed."
        }
    }
    $tsxBin = if ($isWin) { Join-Path $nmDir ".bin/tsx.cmd" } else { Join-Path $nmDir ".bin/tsx" }
    if (Test-Path -LiteralPath $tsxBin) {
        Test-Pass "  tsx binary present: $tsxBin"
    } else {
        Test-Warn "  tsx binary not found at $tsxBin"
    }
}

Write-Section "6. koffi native addon"
if (Test-Path -LiteralPath (Join-Path $nmDir "koffi")) {
    $probe = @'
try {
    const koffi = require("koffi");
    const v = koffi.version || "unknown";
    const probe = process.platform === "win32" ? "kernel32.dll"
        : process.platform === "darwin" ? "libSystem.B.dylib"
        : "libc.so.6";
    koffi.load(probe);
    console.log("KOFFI_OK:" + v + ":" + probe);
} catch (e) {
    console.error("KOFFI_ERR:" + (e && e.message ? e.message : String(e)));
    process.exit(2);
}
'@
    Push-Location -LiteralPath $root
    try {
        $out = & node -e $probe 2>&1
        $rc = $LASTEXITCODE
    } finally {
        Pop-Location
    }
    $outStr = "$out"
    if ($rc -eq 0 -and $outStr -match "KOFFI_OK:") {
        Test-Pass "koffi native addon loads: $outStr"
    } else {
        Test-Fail "koffi native addon failed: $outStr"
    }
} else {
    Test-Warn "koffi not installed; skipping native addon check."
}

Write-Section "7. LingoFuse native library"
$distBinding = Join-Path $root "dist/binding.js"
if (-not (Test-Path -LiteralPath $distBinding)) {
    Test-Warn "dist/binding.js not present; run build.ps1 first. Skipping."
} else {
    $probe = @'
try {
    const b = require("./dist/binding.js");
    const paths = b.buildSearchPaths();
    console.error("SEARCH_PATHS:");
    for (const p of paths) console.error("  " + p);
    const binding = b.getBinding();
    console.log("LOADED:" + binding.libraryName);
} catch (e) {
    console.error("LOAD_ERR:" + (e && e.message ? e.message : String(e)));
    process.exit(2);
}
'@
    Push-Location -LiteralPath $root
    try {
        $out = & node -e $probe 2>&1
        $rc = $LASTEXITCODE
    } finally {
        Pop-Location
    }
    $outStr = "$out"
    if ($rc -eq 0 -and $outStr -match "LOADED:") {
        Test-Pass "Native library loaded."
        Write-Info $outStr
    } else {
        Test-Fail "Native library failed to load."
        Write-Info $outStr
    }
}

Write-Section "8. Report"
if ($script:failures -eq 0 -and $script:warnings -eq 0) {
    Write-Host "  All checks passed. Environment is ready." -ForegroundColor Green
} elseif ($script:failures -eq 0) {
    Write-Host "  All checks passed with $($script:warnings) warning(s)." -ForegroundColor Yellow
} else {
    Write-Host "  $($script:failures) failure(s), $($script:warnings) warning(s)." -ForegroundColor Red
}

if ($script:failures -eq 0) { exit 0 } else { exit 1 }