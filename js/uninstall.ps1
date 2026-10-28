<#
.SYNOPSIS
    Remove the GLOBAL installation of lingofuse-js.

.DESCRIPTION
    Reads the install record written by install.ps1
    (<npm root -g>\lingofuse-js.install.json) and undoes exactly the
    changes that install.ps1 made:

      - remove the directory junction <npm root -g>\lingofuse-js;
      - remove the <npm root -g> entry from USER NODE_PATH, but only
        if install.ps1 was the one that added it;
      - delete the install record itself.

    The script NEVER deletes a real directory. It only removes
    objects whose LinkType is 'Junction'. It does not touch PATH, and
    it does not touch any native library.

    If the install record is missing (for example, it was deleted by
    hand), the script still removes the junction. Pass -Aggressive to
    also remove <npm root -g> from USER NODE_PATH without a record.

.PARAMETER Aggressive
    If the install record is missing, also remove <npm root -g> from
    USER NODE_PATH. Use only when you are certain no other user-level
    configuration relies on that entry.

.EXAMPLE
    cd D:\CoreLibrary\LingoFuse\js
    .\uninstall.ps1
#>

[CmdletBinding()]
param(
    [switch]$Aggressive
)

$ErrorActionPreference = "Stop"

function Write-Info { param([string]$m) Write-Host "[INFO] $m" -ForegroundColor Cyan }
function Write-Ok   { param([string]$m) Write-Host "[ OK ] $m" -ForegroundColor Green }
function Write-Warn { param([string]$m) Write-Host "[WARN] $m" -ForegroundColor Yellow }
function Write-Err  { param([string]$m) Write-Host "[FAIL] $m" -ForegroundColor Red }

function Test-IsJunction {
    param([string]$Path)
    $item = Get-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
    return ($null -ne $item) -and ($item.LinkType -eq "Junction")
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
    Write-Info "Uninstall lingofuse-js from the Node.js GLOBAL node_modules"

    if (-not (Get-Command npm -ErrorAction SilentlyContinue)) {
        throw "npm is not on PATH."
    }

    $globalNM = (& npm root -g 2>$null).Trim()
    if ([string]::IsNullOrWhiteSpace($globalNM)) { throw "`npm root -g` is empty." }
    $globalNM = [System.IO.Path]::GetFullPath($globalNM)
    Write-Info "  Global NM : $globalNM"

    $linkPath   = Join-Path $globalNM "lingofuse-js"
    $recordFile = Join-Path $globalNM "lingofuse-js.install.json"
    $record     = $null

    if (Test-Path -LiteralPath $recordFile) {
        try {
            $record = Get-Content -LiteralPath $recordFile -Raw -Encoding UTF8 | ConvertFrom-Json
            Write-Info "  Record    : $recordFile"
        } catch {
            Write-Warn "Record exists but could not be parsed: $($_.Exception.Message)"
        }
    } else {
        Write-Warn "Install record not found: $recordFile"
    }

    # ---- 1. Remove the junction ----------------------------------------
    if (Test-Path -LiteralPath $linkPath) {
        if (-not (Test-IsJunction $linkPath)) {
            $lt = (Get-Item -LiteralPath $linkPath -Force).LinkType
            Write-Warn "'$linkPath' is not a junction (LinkType=$lt). Refusing to remove."
            Write-Warn "If you installed via 'npm install -g lingofuse-js', use:"
            Write-Warn "    npm uninstall -g lingofuse-js"
        } else {
            Remove-Item -LiteralPath $linkPath -Force -ErrorAction Stop
            Write-Ok "  Removed junction: $linkPath"
        }
    } else {
        Write-Info "  No junction to remove"
    }

    # ---- 2. Remove NODE_PATH entry (only what we added) ----------------
    $npEntries = @()
    if ($record -and ($record.PSObject.Properties.Name -contains "AddedToNodePath")) {
        $npEntries = @($record.AddedToNodePath)
    } elseif ($Aggressive) {
        $npEntries = @($globalNM)
    }

    if ($npEntries.Count -gt 0) {
        Write-Info "Updating USER NODE_PATH ..."
        foreach ($p in $npEntries) { Remove-UserNodePathEntry $p }
    } else {
        Write-Info "Skipping NODE_PATH (no recorded entries; use -Aggressive to force)"
    }

    # ---- 3. Delete the record ------------------------------------------
    if (Test-Path -LiteralPath $recordFile) {
        Remove-Item -LiteralPath $recordFile -Force
        Write-Ok "  Removed install record"
    }

    Write-Host ""
    Write-Ok "Uninstall completed."
    Write-Info "Open a NEW shell for the NODE_PATH change to be visible."
    exit 0

} catch {
    Write-Err $_.Exception.Message
    exit 1
}