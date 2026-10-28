<#
.SYNOPSIS
    Install lingofuse-js into the Node.js GLOBAL node_modules directory.

.DESCRIPTION
    This script does exactly three things and nothing more:

      1. Creates a directory junction at <npm root -g>\lingofuse-js
         pointing at the source tree. Prefers `npm link`, falls back
         to `mklink /J`. Either way it is a live link, not a copy.

      2. Appends <npm root -g> to the USER-level NODE_PATH variable,
         and mirrors it into the current process's NODE_PATH.

      3. Verifies the junction by asking Node to resolve
         `lingofuse-js` starting from the parent of
         <npm root -g>. If that fails, the install is broken.

    The script does NOT touch PATH, does NOT search for or copy any
    native DLLs, and does NOT modify anything outside the Node.js
    global package directory. Native library management is the
    caller's responsibility.

    IMPORTANT LIMITATION (this is Node.js behavior, not a bug in the
    script):

      * NODE_PATH is deprecated in modern Node. It still works for
        CommonJS `require()` in many setups, but it is NOT reliable
        on every Node version and it does NOT work for ESM `import`.

      * The reliable way for an individual project to use this
        package is to run `npm link lingofuse-js` inside that
        project. That creates <project>\node_modules\lingofuse-js as
        a junction to the global install, and Node will find it
        without any environment-variable tricks.

      If the NODE_PATH route does not work on this machine, the
      script prints a WARN (not an ERROR) and does not roll back.
      The global junction is still useful: it is what
      `npm link lingofuse-js` uses.

.PARAMETER SourceDir
    The lingofuse-js source directory. Auto-detected from the
    script's own location if omitted.

.PARAMETER Force
    Recreate the junction even if it already exists and points at a
    different source.

.EXAMPLE
    cd D:\CoreLibrary\LingoFuse\js
    .\install.ps1

.NOTES
    Requires PowerShell 5.1+, npm and node on PATH.
    Junction creation does not require admin if `npm root -g` is
    outside Program Files.
#>

[CmdletBinding()]
param(
    [string]$SourceDir = "",
    [switch]$Force
)

$ErrorActionPreference = "Stop"

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------

function Write-Info { param([string]$m) Write-Host "[INFO] $m" -ForegroundColor Cyan }
function Write-Ok   { param([string]$m) Write-Host "[ OK ] $m" -ForegroundColor Green }
function Write-Warn { param([string]$m) Write-Host "[WARN] $m" -ForegroundColor Yellow }
function Write-Err  { param([string]$m) Write-Host "[FAIL] $m" -ForegroundColor Red }
function Write-Diag { param([string]$m) Write-Host "       $m" -ForegroundColor DarkGray }

# ---------------------------------------------------------------------------
# Path detection
# ---------------------------------------------------------------------------

function Resolve-SourceDir {
    param([string]$Hint)
    $candidates = @(
        $Hint,
        $PSScriptRoot,
        (Join-Path $PSScriptRoot "js"),
        (Join-Path (Split-Path $PSScriptRoot -Parent) "js")
    )
    foreach ($c in $candidates) {
        if ([string]::IsNullOrWhiteSpace($c)) { continue }
        if (-not (Test-Path -LiteralPath $c)) { continue }
        $pkg = Join-Path $c "package.json"
        if (-not (Test-Path -LiteralPath $pkg)) { continue }
        try { $j = Get-Content -LiteralPath $pkg -Raw -Encoding UTF8 | ConvertFrom-Json }
        catch { continue }
        if ($j.name -eq "lingofuse-js") { return [System.IO.Path]::GetFullPath($c) }
    }
    throw "Cannot locate lingofuse-js. Pass -SourceDir explicitly."
}

# ---------------------------------------------------------------------------
# Junction / symlink helpers
# ---------------------------------------------------------------------------

# A link is considered "ours" if it is either a Junction (what mklink /J
# and npm link produce on Windows) or a SymbolicLink (which some npm
# versions produce instead of a junction on Windows).
function Test-IsJunctionOrSymlink {
    param([string]$Path)
    $item = Get-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
    if ($null -eq $item) { return $false }
    return ($item.LinkType -eq "Junction") -or ($item.LinkType -eq "SymbolicLink")
}

function Get-LinkTarget {
    param([string]$Path)
    $item = Get-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
    if ($null -eq $item -or $null -eq $item.Target) { return $null }
    $t = $item.Target
    if ($t -is [array]) { $t = $t[0] }
    return [System.IO.Path]::GetFullPath($t)
}

function New-JunctionByMkLink {
    param([string]$LinkPath, [string]$TargetPath)
    $cmdLine = 'mklink /J "{0}" "{1}"' -f $LinkPath, $TargetPath
    $out = cmd /c $cmdLine 2>&1
    if ($LASTEXITCODE -ne 0) { throw "mklink failed: $out" }
}

function New-LinkByNpmLink {
    param([string]$SourceDir)
    Push-Location -LiteralPath $SourceDir
    try {
        $out = & npm link 2>&1
        if ($LASTEXITCODE -ne 0) {
            return @{ Ok = $false; Output = "$out" }
        }
        return @{ Ok = $true; Output = "$out" }
    } finally {
        Pop-Location
    }
}

# ---------------------------------------------------------------------------
# NODE_PATH helpers
# ---------------------------------------------------------------------------

function Add-UserNodePathEntry {
    param([string]$Item)
    if ([string]::IsNullOrWhiteSpace($Item)) { return @() }
    $Item = $Item.TrimEnd('\', '/')

    $current = [Environment]::GetEnvironmentVariable("NODE_PATH", "User")
    if ($null -eq $current) { $current = "" }

    $parts = @($current -split ';' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })

    foreach ($p in $parts) {
        if ($p.TrimEnd('\', '/') -ieq $Item) {
            Write-Info "  NODE_PATH (User) already contains: $Item"
            return @()
        }
    }

    $parts += $Item
    $combined = $parts -join ';'
    [Environment]::SetEnvironmentVariable("NODE_PATH", $combined, "User")
    Write-Ok "  NODE_PATH (User) += $Item"
    return @($Item)
}

function Sync-ProcessNodePathEntry {
    param([string]$Item)
    if ([string]::IsNullOrWhiteSpace($Item)) { return }
    $Item = $Item.TrimEnd('\', '/')

    $current = $env:NODE_PATH
    if ([string]::IsNullOrWhiteSpace($current)) {
        $env:NODE_PATH = $Item
        [Environment]::SetEnvironmentVariable("NODE_PATH", $Item, "Process")
        return
    }

    $parts = @($current -split ';' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    foreach ($p in $parts) {
        if ($p.TrimEnd('\', '/') -ieq $Item) { return }
    }
    $parts += $Item
    $combined = $parts -join ';'
    $env:NODE_PATH = $combined
    [Environment]::SetEnvironmentVariable("NODE_PATH", $combined, "Process")
}

# ---------------------------------------------------------------------------
# Node resolution probe (no here-string escaping, uses JSON on stdin)
# ---------------------------------------------------------------------------

# Resolve `lingofuse-js` starting from a given directory using Node's own
# module resolution. The directory is passed on stdin as JSON so that
# backslashes, spaces, quotes, and non-ASCII characters are handled
# correctly without any string-escaping puzzles.
function Test-NodeResolve {
    param(
        [string]$StartFromDir,
        [string]$ModuleName
    )
    $payload = @{
        module    = $ModuleName
        startFrom = $StartFromDir
    } | ConvertTo-Json -Compress

    $script = @'
const chunks = [];
process.stdin.on('data', (d) => chunks.push(d));
process.stdin.on('end', () => {
    let req;
    try {
        req = JSON.parse(Buffer.concat(chunks).toString('utf8'));
    } catch (e) {
        console.error('ERR: bad payload: ' + e.message);
        process.exit(3);
    }
    try {
        const resolved = require.resolve(req.module, { paths: [req.startFrom] });
        console.log(resolved);
    } catch (e) {
        console.error('ERR: ' + e.message);
        process.exit(2);
    }
});
'@

    $result = $payload | & node -e $script 2>&1
    return @{
        ExitCode = $LASTEXITCODE
        Output   = "$result"
    }
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

try {
    Write-Info "Install lingofuse-js into the Node.js GLOBAL node_modules"

    # ---- 0. Pre-flight --------------------------------------------------
    if (-not (Get-Command npm  -ErrorAction SilentlyContinue)) { throw "npm is not on PATH." }
    if (-not (Get-Command node -ErrorAction SilentlyContinue)) { throw "node is not on PATH." }

    $nodeVersion = (& node -v 2>$null).Trim()
    $nodeArch    = (& node -p "process.arch" 2>$null).Trim()
    Write-Info "  Node.js    : $nodeVersion ($nodeArch)"

    $SourceDir = Resolve-SourceDir $SourceDir
    Write-Info "  SourceDir  : $SourceDir"

    # ---- 1. Resolve the global node_modules -----------------------------
    $globalNM = (& npm root -g 2>$null).Trim()
    if ([string]::IsNullOrWhiteSpace($globalNM)) {
        throw "`npm root -g` returned an empty path."
    }
    $globalNM = [System.IO.Path]::GetFullPath($globalNM)
    Write-Info "  Global NM  : $globalNM"

    if (-not (Test-Path -LiteralPath $globalNM)) {
        try {
            New-Item -ItemType Directory -Path $globalNM -Force | Out-Null
            Write-Ok "  Created global node_modules directory"
        } catch {
            throw "Cannot create '$globalNM'. Run as Administrator if this is under Program Files."
        }
    }

    # ---- 2. Create or refresh the junction ------------------------------
    $linkPath = Join-Path $globalNM "lingofuse-js"
    $normalizedSource = [System.IO.Path]::GetFullPath($SourceDir).TrimEnd('\','/')

    if (Test-Path -LiteralPath $linkPath) {
        if (-not (Test-IsJunctionOrSymlink $linkPath)) {
            $lt = (Get-Item -LiteralPath $linkPath -Force).LinkType
            throw "'$linkPath' exists but is not a junction or symlink (LinkType=$lt). Remove it manually."
        }
        $existing = Get-LinkTarget $linkPath
        if ($Force) {
            Remove-Item -LiteralPath $linkPath -Force
            Write-Info "  Removed existing link (-Force)"
        } elseif ($existing -ieq $normalizedSource) {
            Write-Ok "  Link already installed -> $normalizedSource"
        } else {
            throw ("Link exists but points elsewhere:`n" +
                   "  expected: $normalizedSource`n" +
                   "  actual  : $existing`n" +
                   "Re-run with -Force to recreate.")
        }
    }

    if (-not (Test-Path -LiteralPath $linkPath)) {
        Write-Info "  Creating link (npm link preferred) ..."
        $npmLinkResult = New-LinkByNpmLink $SourceDir
        if ($npmLinkResult.Ok -and (Test-Path -LiteralPath $linkPath)) {
            Write-Ok "  npm link succeeded"
        } else {
            if (-not $npmLinkResult.Ok) {
                Write-Warn "  npm link failed: $($npmLinkResult.Output)"
            } elseif (-not (Test-Path -LiteralPath $linkPath)) {
                Write-Warn "  npm link reported success but no link was created"
            }
            Write-Info "  Falling back to mklink /J ..."
            New-JunctionByMkLink $linkPath $normalizedSource
            Write-Ok "  Created link via mklink"
        }
    }

    # ---- 3. USER NODE_PATH + current-process mirror --------------------
    Write-Info "Updating USER NODE_PATH ..."
    $addedNodePath = Add-UserNodePathEntry $globalNM
    Sync-ProcessNodePathEntry $globalNM

    # ---- 4. Verify the junction (MUST pass) ----------------------------
    # Start the resolver from the parent of the global node_modules so
    # that Node finds <globalNM>\lingofuse-js via its normal algorithm.
    $parentDir = Split-Path $globalNM -Parent
    Write-Info "Verifying junction integrity ..."
    Write-Diag "  startFrom = $parentDir"
    $probe = Test-NodeResolve -StartFromDir $parentDir -ModuleName "lingofuse-js"
    if ($probe.ExitCode -ne 0) {
        throw ("Junction integrity check failed. Node cannot resolve lingofuse-js `n" +
               "starting from '$parentDir'.`n" +
               $probe.Output)
    }
    Write-Ok "  Junction resolves: $($probe.Output)"

    # ---- 5. Verify the NODE_PATH route (best effort, WARN on failure) --
    Write-Info "Verifying NODE_PATH route ..."
    Write-Diag "  process NODE_PATH = '$($env:NODE_PATH)'"

    $npOk = $false
    Push-Location -LiteralPath $env:TEMP
    try {
        $r = & node -e "try { console.log(require.resolve('lingofuse-js')); } catch(e) { console.error('ERR: ' + e.message); process.exit(2); }" 2>&1
        if ($LASTEXITCODE -eq 0) {
            Write-Ok "  NODE_PATH route works: $r"
            $npOk = $true
        } else {
            Write-Warn "  NODE_PATH route failed: $r"
        }
    } finally {
        Pop-Location
    }

    if (-not $npOk) {
        Write-Host ""
        Write-Warn "NODE_PATH route is NOT active on this machine."
        Write-Warn "This is a Node.js limitation, not a bug in this script."
        Write-Warn "To use lingofuse-js from a project, run once inside that project:"
        Write-Warn "    cd <project-dir>"
        Write-Warn "    npm link lingofuse-js"
        Write-Warn "This creates <project-dir>\node_modules\lingofuse-js as a"
        Write-Warn "junction to the global install and is the supported way."
        Write-Host ""
    }

    # ---- 6. Write the install record -----------------------------------
    $recordFile = Join-Path $globalNM "lingofuse-js.install.json"
    $record = [ordered]@{
        Version           = 1
        InstalledAt       = (Get-Date).ToString("o")
        SourceDir         = $normalizedSource
        GlobalNodeModules = $globalNM
        JunctionPath      = $linkPath
        AddedToNodePath   = @($addedNodePath)
        NodeVersion       = $nodeVersion
        NodePathRouteOk   = $npOk
    }
    $record | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $recordFile -Encoding UTF8
    Write-Ok "  Install record: $recordFile"

    # ---- 7. Final message ----------------------------------------------
    Write-Host ""
    if ($npOk) {
        Write-Ok "Install completed. CommonJS require() should work from anywhere."
    } else {
        Write-Ok "Install completed (global junction installed)."
        Write-Info "  Per-project usage:"
        Write-Info "      cd <project-dir>"
        Write-Info "      npm link lingofuse-js"
    }
    Write-Info "  Uninstall: .\uninstall.ps1"
    exit 0

} catch {
    Write-Err $_.Exception.Message
    Write-Host ""
    Write-Warn "Installation aborted. The junction and NODE_PATH entry that"
    Write-Warn "were already created (if any) were left in place, because"
    Write-Warn "they may still be useful for npm link."
    Write-Warn "To start over, run: .\uninstall.ps1"
    exit 1
}