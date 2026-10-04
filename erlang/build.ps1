#Requires -Version 5.1
<#
.SYNOPSIS
    Build the LingoFuse Erlang NIF binding.

.DESCRIPTION
    Wraps `rebar3 compile` with optional NIF compilation control and
    an optional pre-clean step.

    Build stages:
      1. c_src/build.escript compiles the C sources into priv/.
         This stage is skipped when -SkipNif is given, or when the
         environment variable LINGOFUSE_SKIP_NIF is already set.
      2. rebar3 compiles the Erlang sources under src/.

    The script returns the exit code of the last rebar3 invocation,
    so it is safe to use in CI.

.PARAMETER SkipNif
    Do not compile the C sources. Only the Erlang side is built.
    Useful on Windows hosts without a C compiler, and in CI jobs
    that only verify the Erlang code.

.PARAMETER Clean
    Run clean.ps1 before building.

.EXAMPLE
    .\build.ps1
    Full build: NIF plus Erlang.

.EXAMPLE
    .\build.ps1 -SkipNif
    Erlang-only build.

.EXAMPLE
    .\build.ps1 -Clean
    Clean, then build everything.
#>

[CmdletBinding()]
param(
    [switch]$SkipNif,
    [switch]$Clean
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

# Track exit codes explicitly. This keeps the script working on
# PowerShell 7.3+ where $PSNativeCommandUseErrorActionPreference may
# be enabled by default.
$global:LASTEXITCODE = 0

# --- Paths -----------------------------------------------------------------

$ScriptDir = $PSScriptRoot
$Rebar3    = Join-Path $ScriptDir 'rebar3.cmd'

if (-not (Test-Path -Path $Rebar3 -PathType Leaf)) {
    Write-Host "[FATAL] rebar3.cmd not found next to build.ps1" -ForegroundColor Red
    Write-Host "        Expected: $Rebar3" -ForegroundColor Red
    exit 1
}

# --- Helpers ---------------------------------------------------------------

function Invoke-Step {
    param(
        [Parameter(Mandatory = $true)][string]$Label,
        [Parameter(Mandatory = $true)][scriptblock]$Body
    )
    Write-Host ''
    Write-Host "==> $Label" -ForegroundColor Cyan
    $code = 0
    try {
        & $Body
        if ($null -ne $LASTEXITCODE) { $code = $LASTEXITCODE }
    } catch {
        Write-Host "    exception: $($_.Exception.Message)" -ForegroundColor Red
        $code = 1
    }
    if ($code -eq 0) {
        Write-Host "[ OK ] $Label" -ForegroundColor Green
    } else {
        Write-Host "[FAIL] $Label (exit code $code)" -ForegroundColor Red
    }
    return $code
}

# --- Optional pre-clean ----------------------------------------------------

if ($Clean) {
    $cleanScript = Join-Path $ScriptDir 'clean.ps1'
    if (-not (Test-Path -Path $cleanScript -PathType Leaf)) {
        Write-Host "[FATAL] clean.ps1 not found, cannot honor -Clean" -ForegroundColor Red
        exit 1
    }
    $code = Invoke-Step -Label 'pre-clean' -Body { & $cleanScript }
    if ($code -ne 0) { exit $code }
}

# --- NIF switch ------------------------------------------------------------

if ($SkipNif) {
    $env:LINGOFUSE_SKIP_NIF = '1'
    Write-Host '[info] -SkipNif: LINGOFUSE_SKIP_NIF=1' -ForegroundColor Yellow
} elseif ($env:LINGOFUSE_SKIP_NIF) {
    Write-Host "[info] LINGOFUSE_SKIP_NIF already set: $env:LINGOFUSE_SKIP_NIF" -ForegroundColor Yellow
} else {
    Write-Host '[info] NIF compilation enabled' -ForegroundColor Yellow
}

# --- Compile ---------------------------------------------------------------

Push-Location $ScriptDir
try {
    $code = Invoke-Step -Label 'rebar3 compile' -Body { & $Rebar3 compile }
} finally {
    Pop-Location
}

if ($code -ne 0) { exit $code }

Write-Host ''
Write-Host 'Build completed successfully.' -ForegroundColor Green
exit 0