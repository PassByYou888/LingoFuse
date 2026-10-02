# ============================================================
#  LingoFuse Dart Bridge Build (PowerShell)
#  Compiles lf_dart_bridge.dll using MSVC via vcvars64.bat.
#  Run with:
#      .\build.ps1
#  If blocked by execution policy:
#      powershell -ExecutionPolicy Bypass -File .\build.ps1
# ============================================================

$ErrorActionPreference = 'Stop'

function Write-Header($text) {
    Write-Host ""
    Write-Host ("=" * 60) -ForegroundColor Cyan
    Write-Host "  $text" -ForegroundColor Cyan
    Write-Host ("=" * 60) -ForegroundColor Cyan
}
function Write-Ok($text)   { Write-Host "[OK]   $text" -ForegroundColor Green }
function Write-Fail($text) { Write-Host "[FAIL] $text" -ForegroundColor Red }
function Write-Info($text) { Write-Host "[INFO] $text" -ForegroundColor Gray }

$BridgeDir = $PSScriptRoot
Push-Location $BridgeDir

try {
    Write-Header "LingoFuse Dart Bridge Build"
    Write-Host ""

    # ---- 1. Check required files -------------------------------------
    $required = @(
        @{ Path = 'dart_api_dl.h'; Hint = 'Copy from D:\dart-sdk\include\dart_api_dl.h' },
        @{ Path = 'dart_api_dl.c'; Hint = 'Download from https://raw.githubusercontent.com/dart-lang/sdk/main/runtime/include/dart_api_dl.c' },
        @{ Path = 'lf_dart_bridge.h'; Hint = 'Should already be in this directory' },
        @{ Path = 'lf_dart_bridge.c'; Hint = 'Should already be in this directory' },
        @{ Path = '..\headers\LingoFuse.h'; Hint = 'Should already be at dart\headers\LingoFuse.h' }
    )
    $missing = $false
    foreach ($item in $required) {
        if (-not (Test-Path $item.Path)) {
            Write-Fail "Missing: $($item.Path)"
            Write-Host "       $($item.Hint)" -ForegroundColor Yellow
            $missing = $true
        }
    }
    if ($missing) { exit 1 }
    Write-Ok "All source files present"

    # ---- 2. Locate vcvars64.bat --------------------------------------
    $vcvars = $null
    $vsRoots = @(
        "$env:ProgramFiles\Microsoft Visual Studio\2022",
        "${env:ProgramFiles(x86)}\Microsoft Visual Studio\2022"
    )
    foreach ($root in $vsRoots) {
        if (-not (Test-Path $root)) { continue }
        $editions = Get-ChildItem $root -Directory -ErrorAction SilentlyContinue
        foreach ($ed in $editions) {
            $candidate = Join-Path $ed.FullName 'VC\Auxiliary\Build\vcvars64.bat'
            if (Test-Path $candidate) {
                $vcvars = $candidate
                break
            }
        }
        if ($vcvars) { break }
    }
    if (-not $vcvars) {
        Write-Fail "vcvars64.bat not found under VS2022"
        Write-Info "Install the 'Desktop development with C++' workload."
        exit 1
    }
    Write-Ok "Found vcvars64.bat: $vcvars"

    # ---- 3. Compile via cmd.exe (bat must run in cmd context) --------
    Write-Host ""
    Write-Info "Compiling lf_dart_bridge.dll ..."
    Write-Host ""

    # Build the cl.exe command line. Quote paths in case of spaces.
    $clArgs = @(
        '/nologo',
        '/O2',
        '/LD',
        '/MD',
        '/W3',
        '/I.',
        '/I..\headers',
        'lf_dart_bridge.c',
        'dart_api_dl.c',
        '/Fe:lf_dart_bridge.dll'
    ) -join ' '

    # Single cmd.exe invocation: call vcvars64.bat && cl.exe ...
    $cmdLine = "call `"$vcvars`" >nul 2>&1 && cl.exe $clArgs"

    # Run and capture exit code
    & cmd.exe /c $cmdLine
    $exitCode = $LASTEXITCODE

    if ($exitCode -ne 0) {
        Write-Host ""
        Write-Fail "Compilation failed (cl.exe exit code: $exitCode)"
        exit $exitCode
    }

    # ---- 4. Cleanup intermediate files ------------------------------
    Get-ChildItem -Path . -Filter '*.obj' -File -ErrorAction SilentlyContinue |
        Remove-Item -Force -ErrorAction SilentlyContinue

    # ---- 5. Verify output --------------------------------------------
    $dllPath = Join-Path $BridgeDir 'lf_dart_bridge.dll'
    if (-not (Test-Path $dllPath)) {
        Write-Host ""
        Write-Fail "Compilation reported success but $dllPath was not created"
        exit 1
    }

    $dllSize = (Get-Item $dllPath).Length
    Write-Host ""
    Write-Ok "Built: $dllPath"
    Write-Info "Size:  $dllSize bytes"

    exit 0
}
finally {
    Pop-Location
}