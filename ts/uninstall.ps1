<#
.SYNOPSIS
    Remove lingofuse-ts.

.DESCRIPTION
    Reads the install record written by install.ps1
    (<npm root -g>\lingofuse-ts.install.json) and undoes exactly what
    install.ps1 did:

      - removes the global junction <npm root -g>\lingofuse-ts;
      - removes the project-local junction <ProjectDir>\node_modules\lingofuse-ts
        (either the one recorded, or the one specified with -ProjectDir);
      - removes <npm root -g> from USER NODE_PATH (only what install.ps1 added);
      - deletes the install record.

    The script NEVER deletes a real directory. It only removes objects
    whose LinkType is 'Junction' or 'SymbolicLink'. It does NOT touch
    the source tree, and it does NOT delete dist/.

.PARAMETER ProjectDir
    Also remove the project-local junction in this directory. If the
    install record lists a project-local junction and this parameter
    is omitted, the recorded one is removed.

.PARAMETER Aggressive
    If the install record is missing, also remove <npm root -g> from
    USER NODE_PATH, and try to remove <ProjectDir>\node_modules\lingofuse-ts
    even without a record.

.EXAMPLE
    cd D:\CoreLibrary\LingoFuse\ts
    .\uninstall.ps1

.EXAMPLE
    .\uninstall.ps1 -ProjectDir C:\temp
#>

[CmdletBinding()]
param(
    [string]$ProjectDir = "",
    [switch]$Aggressive
)

$ErrorActionPreference = "Stop"

function Write-Info { param([string]$m) Write-Host "[INFO] $m" -ForegroundColor Cyan }
function Write-Ok   { param([string]$m) Write-Host "[ OK ] $m" -ForegroundColor Green }
function Write-Warn { param([string]$m) Write-Host "[WARN] $m" -ForegroundColor Yellow }
function Write-Err  { param([string]$m) Write-Host "[FAIL] $m" -ForegroundColor Red }

function Get-LinkInfo {
    param([string]$Path)
    $item = Get-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
    if ($null -eq $item) { return $null }
    $target = $null
    if ($item.Target) {
        $target = if ($item.Target -is [array]) { $item.Target[0] } else { $item.Target }
    }
    return @{
        LinkType = $item.LinkType
        Target   = $target
        IsLink   = ($item.LinkType -in @('Junction', 'SymbolicLink'))
    }
}

function Remove-JunctionSafe {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) {
        Write-Info "  Not present: $Path"
        return $true
    }
    $info = Get-LinkInfo $Path
    if ($null -eq $info -or -not $info.IsLink) {
        $lt = if ($null -ne $info) { $info.LinkType } else { "unknown" }
        Write-Warn "  '$Path' is not a junction (LinkType=$lt). Refusing to remove."
        return $false
    }
    try {
        Remove-Item -LiteralPath $Path -Force -ErrorAction Stop
        Write-Ok "  Removed: $Path"
        return $true
    } catch {
        Write-Err "  Failed to remove '$Path': $($_.Exception.Message)"
        return $false
    }
}

function Remove-UserNodePathEntry {
    param([string]$Item)
    if ([string]::IsNullOrWhiteSpace($Item)) { return }
    $Item = $Item.TrimEnd('\', '/')

    $current = [Environment]::GetEnvironmentVariable("NODE_PATH", "User")
    if ([string]::IsNullOrWhiteSpace($current)) {
        Write-Info "  NODE_PATH (User) is empty"
        return
    }
    $parts = @($current -split ';' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    $kept  = @($parts | Where-Object { $_.TrimEnd('\', '/') -ine $Item })

    if ($kept.Count -eq $parts.Count) {
        Write-Info "  NODE_PATH (User) does not contain: $Item"
        return
    }
    [Environment]::SetEnvironmentVariable("NODE_PATH", ($kept -join ';'), "User")
    Write-Ok "  NODE_PATH (User) -= $Item"
}

try {
    Write-Info "Uninstall lingofuse-ts"

    if (-not (Get-Command npm -ErrorAction SilentlyContinue)) {
        throw "npm is not on PATH."
    }
    $globalNM = (& npm root -g 2>$null).Trim()
    if ([string]::IsNullOrWhiteSpace($globalNM)) { throw "npm root -g is empty." }
    $globalNM = [System.IO.Path]::GetFullPath($globalNM)
    Write-Info "  Global  : $globalNM"

    $globalLink = Join-Path $globalNM "lingofuse-ts"
    $recordFile = Join-Path $globalNM "lingofuse-ts.install.json"
    $record = $null

    if (Test-Path -LiteralPath $recordFile) {
        try {
            $record = Get-Content -LiteralPath $recordFile -Raw -Encoding UTF8 | ConvertFrom-Json
            Write-Info "  Record  : $recordFile"
        } catch {
            Write-Warn "  Record could not be parsed: $($_.Exception.Message)"
        }
    } else {
        Write-Warn "  Install record not found: $recordFile"
    }

    # ---- 1. Global junction -------------------------------------------
    Remove-JunctionSafe $globalLink | Out-Null

    # ---- 2. Project-local junction ------------------------------------
    $pd = $ProjectDir
    if ([string]::IsNullOrWhiteSpace($pd) -and $null -ne $record -and
        -not [string]::IsNullOrWhiteSpace($record.ProjectDir)) {
        $pd = $record.ProjectDir
    }
    if ([string]::IsNullOrWhiteSpace($pd) -and $Aggressive -and $null -eq $record) {
        Write-Info "  No -ProjectDir and no record; skipping project-local cleanup."
    }
    if (-not [string]::IsNullOrWhiteSpace($pd)) {
        $pdAbs = [System.IO.Path]::GetFullPath($pd)
        $projectLink = Join-Path (Join-Path $pdAbs "node_modules") "lingofuse-ts"
        Write-Info "  Project : $pdAbs"
        Remove-JunctionSafe $projectLink | Out-Null
    }

    # ---- 3. NODE_PATH -------------------------------------------------
    $npEntries = @()
    if ($null -ne $record -and $record.PSObject.Properties.Name -contains "AddedToNodePath") {
        $npEntries = @($record.AddedToNodePath)
    } elseif ($Aggressive -or $null -ne $record) {
        $npEntries = @($globalNM)
    }
    if ($npEntries.Count -gt 0) {
        Write-Info "Updating USER NODE_PATH ..."
        foreach ($p in $npEntries) { Remove-UserNodePathEntry $p }
    }

    # ---- 4. Record ----------------------------------------------------
    if (Test-Path -LiteralPath $recordFile) {
        Remove-Item -LiteralPath $recordFile -Force -ErrorAction Stop
        Write-Ok "  Removed install record"
    }

    Write-Host ""
    Write-Ok "Uninstall completed."
    Write-Info "Open a NEW shell for NODE_PATH changes to take effect."
    exit 0

} catch {
    Write-Err $_.Exception.Message
    exit 1
}