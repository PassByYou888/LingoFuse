#Requires -Version 5.1
<#
.SYNOPSIS
    Run the LingoFuse Erlang NIF binding test suites.

.DESCRIPTION
    Invokes `rebar3 eunit` with optional controls.

    Test suites:
        lingofuse_abi_tests        C ABI layer
        lingofuse_json_tests       JSON wire format
        lingofuse_network_tests    C4 mesh
        lingofuse_sync_tests       Sync callback bridge

    When the LingoFuse native library is not on the loader search
    path, every suite prints a SKIP message and the run still exits
    with status 0. Use -RequireNative (or set the environment
    variable LINGOFUSE_REQUIRE_NATIVE=1) to turn a missing library
    into a hard failure. That is the correct behaviour in CI.

.PARAMETER RequireNative
    Fail when the native library is not available.

.PARAMETER Suite
    Restrict execution to a single suite, for example
    'lingofuse_json_tests'.

.PARAMETER SkipNif
    Skip the NIF build. Set this on hosts without a C compiler.

.EXAMPLE
    .\test.ps1
    Run every suite in lenient mode.

.EXAMPLE
    .\test.ps1 -RequireNative
    CI mode: a missing native library is a hard failure.

.EXAMPLE
    .\test.ps1 -Suite lingofuse_sync_tests
    Run only the sync bridge suite.
#>

[CmdletBinding()]
param(
    [switch]$RequireNative,
    [string]$Suite,
    [switch]$SkipNif
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$global:LASTEXITCODE = 0

# --- Paths -----------------------------------------------------------------

$ScriptDir = $PSScriptRoot
$Rebar3    = Join-Path $ScriptDir 'rebar3.cmd'

if (-not (Test-Path -Path $Rebar3 -PathType Leaf)) {
    Write-Host '[FATAL] rebar3.cmd not found next to test.ps1' -ForegroundColor Red
    exit 1
}

# --- Environment -----------------------------------------------------------

if ($RequireNative) {
    $env:LINGOFUSE_REQUIRE_NATIVE = '1'
    Write-Host '[info] -RequireNative: LINGOFUSE_REQUIRE_NATIVE=1' -ForegroundColor Yellow
}

if ($SkipNif) {
    $env:LINGOFUSE_SKIP_NIF = '1'
    Write-Host '[info] -SkipNif: LINGOFUSE_SKIP_NIF=1' -ForegroundColor Yellow
}

# --- Build argument vector -------------------------------------------------

$eunitArgs = @('eunit')

if ($PSBoundParameters.ContainsKey('Suite') -and $Suite -ne '') {
    $eunitArgs += "--module=$Suite"
}

# CmdletBinding supplies -Verbose; forward it to eunit as -v.
if ($VerbosePreference -eq 'Continue') {
    $eunitArgs += '-v'
}

# --- Run -------------------------------------------------------------------

Push-Location $ScriptDir
try {
    Write-Host ''
    Write-Host ("==> rebar3 {0}" -f ($eunitArgs -join ' ')) -ForegroundColor Cyan
    & $Rebar3 @eunitArgs
    $code = $LASTEXITCODE
} finally {
    Pop-Location
}

# --- Report ----------------------------------------------------------------

Write-Host ''
if ($code -eq 0) {
    Write-Host 'Tests passed.' -ForegroundColor Green
} else {
    Write-Host "Tests failed (exit code $code)." -ForegroundColor Red
}

exit $code