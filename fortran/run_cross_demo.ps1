<#
.SYNOPSIS
    Launch the cross-language demo: beacon, node, and both callers.

.DESCRIPTION
    Opens the beacon and the Fortran worker node in two new PowerShell
    windows, waits for the mesh to settle, then runs the Fortran
    caller and the C++ caller in the current window.

    This automates the sequencing that the demo requires:

        1. cross_service.exe        (beacon)
        2. cross_node.exe           (Fortran worker, registers "demo")
        3. wait ~5 s for the mesh broadcast to propagate
        4. cross_call.exe           (Fortran caller, same-language baseline)
        5. cross_call_cpp.exe       (C++ caller, cross-language verification)

    Runtime DLLs are not handled by this script. The C++ bridge
    resolves the LingoFuse runtime through the standard OS loader
    search order (executable directory, then system PATH). If a
    caller fails with "Failed to load LingoFuse64.dll", check that
    the runtime is on PATH or next to the executable.

.PARAMETER WaitSeconds
    How long to wait between starting the node and running the first
    caller. Default: 5. Increase to 8 if your machine is slow.

.PARAMETER SkipFortranCaller
    Do not run the Fortran caller. Only run the C++ caller.

.EXAMPLE
    .\run_cross_demo.ps1
    Launch the full demo.

.EXAMPLE
    .\run_cross_demo.ps1 -WaitSeconds 8
    Use a longer warm-up delay.
#>

[CmdletBinding()]
param(
    [int]$WaitSeconds = 5,
    [switch]$SkipFortranCaller
)

$ErrorActionPreference = 'Stop'

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$DemoDir   = Join-Path $ScriptDir 'cross_demo'

# ---------------------------------------------------------------------------
# Pre-flight check: only the executables, not the DLLs.
# ---------------------------------------------------------------------------

$required = @(
    'cross_service.exe',
    'cross_node.exe',
    'cross_call.exe',
    'cross_call_cpp.exe'
)

$missing = @()
foreach ($name in $required) {
    if (-not (Test-Path -LiteralPath (Join-Path $DemoDir $name))) {
        $missing += $name
    }
}

if ($missing.Count -gt 0) {
    Write-Host ''
    Write-Host '[FATAL] Required executables are missing from cross_demo\:' -ForegroundColor Red
    foreach ($m in $missing) {
        Write-Host ("        {0}" -f $m) -ForegroundColor Red
    }
    Write-Host ''
    Write-Host '  Build the demo with:  .\build.ps1 -Target cross_demo' -ForegroundColor Yellow
    exit 2
}

Write-Host ''
Write-Host '======================================================================' -ForegroundColor Cyan
Write-Host '  LingoFuse cross-language demo' -ForegroundColor Cyan
Write-Host '======================================================================' -ForegroundColor Cyan
Write-Host ("  Demo dir   : {0}" -f $DemoDir)
Write-Host ("  Warm-up    : {0} seconds" -f $WaitSeconds)
Write-Host ''

# ---------------------------------------------------------------------------
# Step 1: launch the beacon in a new window
# ---------------------------------------------------------------------------

Write-Host '[1/4] Launching beacon (cross_service.exe) in a new window...' -ForegroundColor Yellow
Start-Process -FilePath (Join-Path $DemoDir 'cross_service.exe') `
              -WorkingDirectory $DemoDir
Start-Sleep -Seconds 2

# ---------------------------------------------------------------------------
# Step 2: launch the Fortran worker in a new window
# ---------------------------------------------------------------------------

Write-Host '[2/4] Launching Fortran worker (cross_node.exe) in a new window...' -ForegroundColor Yellow
Start-Process -FilePath (Join-Path $DemoDir 'cross_node.exe') `
              -WorkingDirectory $DemoDir

# ---------------------------------------------------------------------------
# Step 3: warm-up delay for mesh broadcast propagation
# ---------------------------------------------------------------------------

Write-Host ("[3/4] Waiting {0} s for the mesh broadcast to settle..." -f $WaitSeconds) -ForegroundColor Yellow
for ($i = $WaitSeconds; $i -gt 0; --$i) {
    Write-Host ("      ... {0}" -f $i)
    Start-Sleep -Seconds 1
}

# ---------------------------------------------------------------------------
# Step 4: run the callers in the current window
# ---------------------------------------------------------------------------

$exitCode = 0

if (-not $SkipFortranCaller) {
    Write-Host ''
    Write-Host '[4/4a] Running Fortran caller (same-language baseline)...' -ForegroundColor Yellow
    Push-Location -LiteralPath $DemoDir
    try {
        & '.\cross_call.exe' | Out-Host
        if ($LASTEXITCODE -ne 0) { $exitCode = 1 }
    }
    finally {
        Pop-Location
    }
}

Write-Host ''
Write-Host '[4/4b] Running C++ caller (cross-language verification)...' -ForegroundColor Yellow
Push-Location -LiteralPath $DemoDir
try {
    & '.\cross_call_cpp.exe' | Out-Host
    if ($LASTEXITCODE -ne 0) { $exitCode = 1 }
}
finally {
    Pop-Location
}

# ---------------------------------------------------------------------------
# Final verdict
# ---------------------------------------------------------------------------

Write-Host ''
if ($exitCode -eq 0) {
    Write-Host '[OK] Cross-language demo completed successfully.' -ForegroundColor Green
    Write-Host '     Close the two extra windows (beacon, node) when done.' -ForegroundColor Green
}
else {
    Write-Host '[ERROR] One or more callers failed.' -ForegroundColor Red
    Write-Host '        Check the beacon and node windows for errors.' -ForegroundColor Red
}

Write-Host ''
exit $exitCode