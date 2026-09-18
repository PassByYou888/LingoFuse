# =============================================================================
# build_bridge.ps1
#
# Compiles the HTTP bridge gateway:
#
#     bridge.exe    - HTTP-to-LingoFuse passthrough gateway
#
# Output goes to .\dist\.
#
# Notes:
#   * bridge.py lives in the lingofuse\ subpackage. The script is intended
#     to be run from the src\ directory, so the source path is
#     .\lingofuse\bridge.py.
#   * bridge.py depends on Flask. Flask's Jinja2 dependency ships
#     templates and its templating engine loads them at runtime, so
#     --collect-all flask and --collect-all jinja2 are required.
#   * bridge.py still uses requests for one optional probe path; if
#     that probe is not exercised, requests is not needed. It is
#     declared as a hidden import so that the packaged exe still works
#     when the caller passes --debug and the probe runs.
#
# Usage:
#     cd src
#     .\build_bridge.ps1
# =============================================================================

$ErrorActionPreference = "Stop"

if (-not (Test-Path ".\lingofuse\bridge.py")) {
    Write-Host "[FATAL] lingofuse\bridge.py not found in the current directory." -ForegroundColor Red
    Write-Host "        Run this script from the src\ directory that contains" -ForegroundColor Red
    Write-Host "        the lingofuse\ subpackage." -ForegroundColor Red
    exit 1
}

$pyinstaller = Get-Command pyinstaller -ErrorAction SilentlyContinue
if (-not $pyinstaller) {
    Write-Host "[FATAL] pyinstaller is not on PATH." -ForegroundColor Red
    Write-Host "        Install it with: pip install pyinstaller" -ForegroundColor Red
    exit 1
}

Write-Host ""
Write-Host "==== Building bridge.exe ====" -ForegroundColor Cyan

$common_args = @(
    "--onefile",
    "--name", "bridge",
    "--noconfirm",
    "--clean",
    "--paths", ".",
    "--collect-submodules", "lingofuse",
    "--collect-all", "flask",
    "--collect-all", "jinja2",
    "--hidden-import", "requests"
)

$full_args = $common_args + @("lingofuse\bridge.py")
Write-Host "  pyinstaller $($full_args -join ' ')" -ForegroundColor DarkGray

$ok = $false
try {
    & pyinstaller @full_args
    if ($LASTEXITCODE -ne 0) {
        throw "pyinstaller exited with code $LASTEXITCODE"
    }
    $ok = $true
    Write-Host "  [OK] bridge.exe" -ForegroundColor Green
}
catch {
    Write-Host "  [FAILED] bridge.exe : $_" -ForegroundColor Red
}

Write-Host ""
Write-Host "==== Build summary ====" -ForegroundColor Cyan
if ($ok) {
    Write-Host ("  {0,-20} {1}" -f "bridge", "OK") -ForegroundColor Green
    Write-Host ""
    Write-Host "Output directory: .\dist\" -ForegroundColor Cyan
    Write-Host "Runtime dependency: LingoFuse64.dll + z_ipc_64.dll must be on PATH" -ForegroundColor Cyan
    exit 0
}
else {
    Write-Host ("  {0,-20} {1}" -f "bridge", "FAILED") -ForegroundColor Red
    exit 1
}