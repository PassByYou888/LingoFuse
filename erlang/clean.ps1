#Requires -Version 5.1
<#
.SYNOPSIS
    Remove build artefacts from the LingoFuse Erlang NIF binding.

.DESCRIPTION
    Removes generated files in three cumulative levels:

      Default:
          rebar3 clean
          c_src/*.o
          stray *.o files in the project root

      -Deep:
          everything from the default level, plus
          _build/
          priv/lingofuse_nif.{dll,so,dylib}

      -All:
          everything from -Deep, plus
          rebar.lock
          any *.plt files under _build/

    The script is idempotent: it can be run any number of times.

.PARAMETER Deep
    Also remove _build/ and the compiled NIF under priv/.

.PARAMETER All
    Also remove rebar.lock and any dialyzer PLT files.

.PARAMETER DryRun
    Print what would be removed without deleting anything.

.EXAMPLE
    .\clean.ps1
    Default clean.

.EXAMPLE
    .\clean.ps1 -Deep
    Full artefact clean.

.EXAMPLE
    .\clean.ps1 -All -DryRun
    Preview a full clean.
#>

[CmdletBinding()]
param(
    [switch]$Deep,
    [switch]$All,
    [switch]$DryRun
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$global:LASTEXITCODE = 0

if ($All) {
    $Deep = $true
}

# --- Paths -----------------------------------------------------------------

$ScriptDir = $PSScriptRoot
$Rebar3    = Join-Path $ScriptDir 'rebar3.cmd'

if (-not (Test-Path -Path $Rebar3 -PathType Leaf)) {
    Write-Host '[WARN] rebar3.cmd not found; skipping rebar3 clean' -ForegroundColor Yellow
    $Rebar3 = $null
}

# --- Helpers ---------------------------------------------------------------

function Remove-PathSafe {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Label
    )
    if (-not (Test-Path -Path $Path)) {
        Write-Host ("    skip (not found): {0}" -f $Label) -ForegroundColor DarkGray
        return
    }
    if ($DryRun) {
        Write-Host ("    would remove: {0}" -f $Label) -ForegroundColor Yellow
        return
    }
    try {
        Remove-Item -Path $Path -Recurse -Force -ErrorAction Stop
        Write-Host ("    removed: {0}" -f $Label) -ForegroundColor Green
    } catch {
        Write-Host ("    failed to remove: {0} ({1})" -f $Label, $_.Exception.Message) -ForegroundColor Red
    }
}

function Remove-FilesByPattern {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][string]$Filter,
        [Parameter(Mandatory = $true)][string]$LabelPrefix
    )
    if (-not (Test-Path -Path $Root)) {
        Write-Host ("    skip (no dir): {0}" -f $Root) -ForegroundColor DarkGray
        return
    }
    $items = Get-ChildItem -Path $Root -Filter $Filter -File -ErrorAction SilentlyContinue
    if ($null -eq $items -or $items.Count -eq 0) {
        Write-Host ("    skip (no matches): {0}/{1}" -f $LabelPrefix, $Filter) -ForegroundColor DarkGray
        return
    }
    foreach ($item in $items) {
        Remove-PathSafe -Path $item.FullName -Label ($LabelPrefix + '/' + $item.Name)
    }
}

# --- Step 1: rebar3 clean --------------------------------------------------

Write-Host ''
Write-Host '==> rebar3 clean' -ForegroundColor Cyan
if ($null -ne $Rebar3) {
    if ($DryRun) {
        Write-Host '    would run: rebar3 clean' -ForegroundColor Yellow
    } else {
        Push-Location $ScriptDir
        try {
            & $Rebar3 clean
            $code = $LASTEXITCODE
        } finally {
            Pop-Location
        }
        if ($code -eq 0) {
            Write-Host '    rebar3 clean completed' -ForegroundColor Green
        } else {
            Write-Host ("    rebar3 clean returned exit code {0}" -f $code) -ForegroundColor Yellow
        }
    }
} else {
    Write-Host '    skipped (rebar3.cmd not available)' -ForegroundColor DarkGray
}

# --- Step 2: object files --------------------------------------------------

Write-Host ''
Write-Host '==> object files' -ForegroundColor Cyan
Remove-FilesByPattern -Root (Join-Path $ScriptDir 'c_src') -Filter '*.o' -LabelPrefix 'c_src'
Remove-FilesByPattern -Root $ScriptDir                      -Filter '*.o' -LabelPrefix '.'

# --- Step 3: deep clean ----------------------------------------------------

if ($Deep) {
    Write-Host ''
    Write-Host '==> deep clean' -ForegroundColor Cyan
    Remove-PathSafe -Path (Join-Path $ScriptDir '_build') -Label '_build/'

    $privDir = Join-Path $ScriptDir 'priv'
    Remove-FilesByPattern -Root $privDir -Filter 'lingofuse_nif.dll'   -LabelPrefix 'priv'
    Remove-FilesByPattern -Root $privDir -Filter 'lingofuse_nif.so'    -LabelPrefix 'priv'
    Remove-FilesByPattern -Root $privDir -Filter 'lingofuse_nif.dylib' -LabelPrefix 'priv'
}

# --- Step 4: full clean ----------------------------------------------------

if ($All) {
    Write-Host ''
    Write-Host '==> full clean' -ForegroundColor Cyan
    Remove-PathSafe -Path (Join-Path $ScriptDir 'rebar.lock') -Label 'rebar.lock'
}

# --- Summary ---------------------------------------------------------------

Write-Host ''
if ($DryRun) {
    Write-Host 'Dry run completed. No files were deleted.' -ForegroundColor Yellow
} else {
    Write-Host 'Clean completed.' -ForegroundColor Green
}
exit 0