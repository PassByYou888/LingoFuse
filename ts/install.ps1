<#
.SYNOPSIS
    Install lingofuse-ts so that a standalone TypeScript file can
    `import * as lf from "lingofuse-ts"` without source changes.

.DESCRIPTION
    Four steps:
      1. Ensure lingofuse-ts/dist/index.js and dist/index.d.ts exist.
      2. Create a GLOBAL junction <npm root -g>\lingofuse-ts -> <SourceDir>
         and append <npm root -g> to USER NODE_PATH.
      3. If -ProjectDir is supplied, create a PROJECT-LOCAL junction
         <ProjectDir>\node_modules\lingofuse-ts -> <SourceDir>.
      4. Verify by reading files THROUGH the junction.

    JUNCTION CREATION STRATEGIES
    ----------------------------
    Both strategies run inside [System.Diagnostics.ProcessStartInfo]
    or pure .NET APIs. We NEVER shell out with `& cmd.exe /d /c $str`
    because PowerShell 7's native argument passing (and, on some
    PSReadLine builds, the `2>&1` redirection itself) raises
    "The parameter set cannot be resolved" for that exact spelling.

      1. mklink /J via ProcessStartInfo
         Preferred. Creates a real junction; no SeCreateSymbolicLinkPrivilege needed.
      2. [System.IO.Directory]::CreateSymbolicLink
         Fallback. Creates a symbolic link; requires admin or Developer Mode.

    Every created link is verified by reading a real file through it.

.PARAMETER SourceDir
    The lingofuse-ts source directory. Auto-detected from the script's
    own location if omitted.

.PARAMETER ProjectDir
    Directory that holds your standalone .ts file(s).

.PARAMETER Force
    Recreate the junctions even if they already exist.

.PARAMETER SkipVerify
    Skip the final Node `require.resolve` probe. Filesystem check is
    always performed.
#>

[CmdletBinding()]
param(
    [string]$SourceDir  = "",
    [string]$ProjectDir = "",
    [switch]$Force,
    [switch]$SkipVerify
)

$ErrorActionPreference = "Stop"

# ===========================================================================
# Logging
# ===========================================================================

function Write-Info { param([string]$m) Write-Host "[INFO] $m" -ForegroundColor Cyan }
function Write-Ok   { param([string]$m) Write-Host "[ OK ] $m" -ForegroundColor Green }
function Write-Warn { param([string]$m) Write-Host "[WARN] $m" -ForegroundColor Yellow }
function Write-Err  { param([string]$m) Write-Host "[FAIL] $m" -ForegroundColor Red }
function Write-Diag { param([string]$m) Write-Host "       $m" -ForegroundColor DarkGray }

# ===========================================================================
# Source dir detection
# ===========================================================================

function Resolve-SourceDir {
    param([string]$Hint)
    $candidates = @(
        $Hint,
        $PSScriptRoot,
        (Join-Path $PSScriptRoot "ts"),
        (Join-Path (Split-Path $PSScriptRoot -Parent) "ts")
    ) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }

    foreach ($c in $candidates) {
        if (-not [System.IO.Directory]::Exists($c)) { continue }
        $pkg = Join-Path $c "package.json"
        if (-not [System.IO.File]::Exists($pkg)) { continue }
        try {
            $j = Get-Content -LiteralPath $pkg -Raw -Encoding UTF8 | ConvertFrom-Json
        } catch { continue }
        if ($j.name -eq "lingofuse-ts") {
            return [System.IO.Path]::GetFullPath($c)
        }
    }
    throw "Cannot locate lingofuse-ts source. Pass -SourceDir explicitly."
}

# ===========================================================================
# Link helpers
# ===========================================================================

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

# Completely PowerShell-cmdlet-free path manipulation.
function Remove-PathObject {
    param([string]$Path)
    if ([System.IO.Directory]::Exists($Path) -or [System.IO.File]::Exists($Path)) {
        try {
            # Delete with recursive=$false so we never touch a real
            # directory's contents.
            [System.IO.Directory]::Delete($Path, $false)
        } catch {
            try { [System.IO.File]::Delete($Path) } catch { }
        }
    }
}

# Strategy 1: mklink /J via ProcessStartInfo (isolated from PowerShell).
function Invoke-MkLink {
    param([string]$LinkPath, [string]$TargetPath)

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = 'cmd.exe'
    # Build the argument string by hand. Do NOT use `-f`/`-replace` and
    # do NOT pass /d /c and the rest as separate PowerShell arguments:
    # on PowerShell 7.6 this triggers the parameter-set binder for reasons
    # that are not worth chasing. ProcessStartInfo.Arguments is a raw
    # command line, so cmd.exe sees exactly what we put here.
    $psi.Arguments = '/d /c mklink /J "' + $LinkPath + '" "' + $TargetPath + '"'
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.StandardOutputEncoding = [System.Text.Encoding]::UTF8
    $psi.StandardErrorEncoding  = [System.Text.Encoding]::UTF8

    $proc = [System.Diagnostics.Process]::Start($psi)
    $stdout = $proc.StandardOutput.ReadToEnd()
    $stderr = $proc.StandardError.ReadToEnd()
    $proc.WaitForExit()
    $rc = $proc.ExitCode

    return @{
        ExitCode = $rc
        StdOut   = "$stdout".Trim()
        StdErr   = "$stderr".Trim()
    }
}

# Strategy 2: .NET symbol-link fallback.
function Invoke-CreateSymbolicLink {
    param([string]$LinkPath, [string]$TargetPath)
    try {
        $null = [System.IO.Directory]::CreateSymbolicLink($LinkPath, $TargetPath)
        return @{ Ok = $true; Error = $null }
    } catch {
        return @{ Ok = $false; Error = $_.Exception.Message }
    }
}

function New-DirectoryJunction {
    param([string]$LinkPath, [string]$TargetPath)

    # Parent directory (pure .NET, no Split-Path / New-Item).
    $parent = [System.IO.Path]::GetDirectoryName($LinkPath)
    if (-not [string]::IsNullOrWhiteSpace($parent) -and
        -not [System.IO.Directory]::Exists($parent)) {
        [void][System.IO.Directory]::CreateDirectory($parent)
    }

    if ([System.IO.Directory]::Exists($LinkPath) -or [System.IO.File]::Exists($LinkPath)) {
        throw "'$LinkPath' already exists and was not removed. Re-run with -Force."
    }

    $attempts = @()

    # ---- Strategy 1: mklink /J ----
    Write-Diag "  [strategy 1] mklink /J"
    try {
        $r = Invoke-MkLink -LinkPath $LinkPath -TargetPath $TargetPath
    } catch {
        $attempts += "mklink threw: $($_.Exception.Message)"
        $r = $null
    }
    if ($null -ne $r) {
        if ($r.ExitCode -ne 0) {
            $attempts += "mklink exit $($r.ExitCode); stderr=[$($r.StdErr)]; stdout=[$($r.StdOut)]"
        } elseif (-not [System.IO.Directory]::Exists($LinkPath)) {
            $attempts += "mklink exit 0 but '$LinkPath' does not exist; stdout=[$($r.StdOut)]"
        } else {
            $info = Get-LinkInfo $LinkPath
            if ($null -ne $info -and $info.IsLink) {
                return   # success
            }
            $attempts += "mklink created an object but Get-LinkInfo says LinkType='$($info.LinkType)'"
        }
    }
    Remove-PathObject $LinkPath

    # ---- Strategy 2: Directory.CreateSymbolicLink ----
    Write-Diag "  [strategy 2] Directory.CreateSymbolicLink"
    $s = Invoke-CreateSymbolicLink -LinkPath $LinkPath -TargetPath $TargetPath
    if ($s.Ok -and [System.IO.Directory]::Exists($LinkPath)) {
        $info = Get-LinkInfo $LinkPath
        if ($null -ne $info -and $info.IsLink) {
            return   # success
        }
        $attempts += "CreateSymbolicLink returned but Get-LinkInfo says LinkType='$($info.LinkType)'"
    } else {
        $attempts += "CreateSymbolicLink failed: $($s.Error)"
    }
    Remove-PathObject $LinkPath

    throw ("All link-creation strategies failed.`n" +
           "  Link:   $LinkPath`n" +
           "  Target: $TargetPath`n" +
           "Attempts:`n    - " + ($attempts -join "`n    - "))
}

function Initialize-Junction {
    param(
        [string]$LinkPath,
        [string]$TargetPath,
        [switch]$ForceIt
    )
    $normalized = [System.IO.Path]::GetFullPath($TargetPath).TrimEnd('\', '/')

    if ([System.IO.Directory]::Exists($LinkPath) -or [System.IO.File]::Exists($LinkPath)) {
        $info = Get-LinkInfo $LinkPath
        if ($null -eq $info -or -not $info.IsLink) {
            $lt = if ($null -ne $info) { $info.LinkType } else { 'unknown' }
            throw "'$LinkPath' exists but is not a link (LinkType=$lt). Remove it manually."
        }
        $existing = if ($info.Target) { [System.IO.Path]::GetFullPath($info.Target).TrimEnd('\', '/') } else { '' }
        if ($ForceIt) {
            Remove-PathObject $LinkPath
            Write-Info "  Removed existing link: $LinkPath"
        } elseif ($existing -ieq $normalized) {
            Write-Ok "  Link already installed: $LinkPath"
            return
        } else {
            throw "Link exists but points elsewhere.`n  expected: $normalized`n  actual  : $existing`nRe-run with -Force."
        }
    }

    New-DirectoryJunction -LinkPath $LinkPath -TargetPath $normalized

    # Final verification.
    if (-not [System.IO.Directory]::Exists($LinkPath)) {
        throw "Junction creation reported success, but '$LinkPath' does not exist."
    }
    $info = Get-LinkInfo $LinkPath
    if ($null -eq $info -or -not $info.IsLink) {
        throw "Final check: '$LinkPath' is not a link."
    }
    $actual = [System.IO.Path]::GetFullPath($info.Target).TrimEnd('\', '/')
    if ($actual -ine $normalized) {
        throw "Final check: junction target mismatch.`n  expected: $normalized`n  actual  : $actual"
    }
    $probe = Join-Path $LinkPath "package.json"
    if (-not [System.IO.File]::Exists($probe)) {
        throw "Final check: '$probe' is not reachable through the junction."
    }

    Write-Ok "  Created link: $LinkPath"
    Write-Diag "           -> $normalized"
}

# ===========================================================================
# NODE_PATH helpers
# ===========================================================================

function Add-UserNodePathEntry {
    param([string]$Item)
    if ([string]::IsNullOrWhiteSpace($Item)) { return }
    $Item = $Item.TrimEnd('\', '/')

    $current = [Environment]::GetEnvironmentVariable("NODE_PATH", "User")
    if ($null -eq $current) { $current = "" }

    $parts = @($current -split ';' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    foreach ($p in $parts) {
        if ($p.TrimEnd('\', '/') -ieq $Item) {
            Write-Info "  NODE_PATH (User) already contains: $Item"
            return
        }
    }
    $parts += $Item
    [Environment]::SetEnvironmentVariable("NODE_PATH", ($parts -join ';'), "User")
    Write-Ok "  NODE_PATH (User) += $Item"
}

function Sync-ProcessNodePathEntry {
    param([string]$Item)
    if ([string]::IsNullOrWhiteSpace($Item)) { return }
    $Item = $Item.TrimEnd('\', '/')

    $current = $env:NODE_PATH
    if ([string]::IsNullOrWhiteSpace($current)) {
        $env:NODE_PATH = $Item
        return
    }
    $parts = @($current -split ';' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    foreach ($p in $parts) {
        if ($p.TrimEnd('\', '/') -ieq $Item) { return }
    }
    $parts += $Item
    $env:NODE_PATH = ($parts -join ';')
}

# ===========================================================================
# Build check
# ===========================================================================

function Initialize-Dist {
    param([string]$TsDir)
    $distJs   = Join-Path $TsDir "dist\index.js"
    $distDts  = Join-Path $TsDir "dist\index.d.ts"
    $srcIndex = Join-Path $TsDir "src\index.ts"

    if (-not [System.IO.File]::Exists($srcIndex)) {
        throw "Source tree is missing src\index.ts. '$TsDir' does not look like lingofuse-ts."
    }
    if ([System.IO.File]::Exists($distJs) -and [System.IO.File]::Exists($distDts)) {
        Write-Ok "  dist\index.js and dist\index.d.ts exist"
        return
    }

    Write-Info "  dist\ is missing or incomplete; running 'npm run build' ..."
    Push-Location -LiteralPath $TsDir
    try {
        if (-not [System.IO.Directory]::Exists((Join-Path $TsDir "node_modules"))) {
            Write-Info "  node_modules is missing; running 'npm install' first ..."
            $out = & npm install 2>&1
            if ($LASTEXITCODE -ne 0) { throw "npm install failed:`n$out" }
        }
        $out = & npm run build 2>&1
        if ($LASTEXITCODE -ne 0) { throw "npm run build failed:`n$out" }
    } finally {
        Pop-Location
    }

    if (-not [System.IO.File]::Exists($distJs))  { throw "npm run build did not produce '$distJs'." }
    if (-not [System.IO.File]::Exists($distDts)) { throw "npm run build did not produce '$distDts'. Check tsconfig.build.json (declaration must be true)." }
    Write-Ok "  Build completed"
}

# ===========================================================================
# Verification
# ===========================================================================

function Test-PackageOnDisk {
    param(
        [string]$ProjectDir,
        [string]$ModuleName = "lingofuse-ts"
    )
    $linkPath = Join-Path (Join-Path $ProjectDir "node_modules") $ModuleName
    if (-not [System.IO.Directory]::Exists($linkPath)) {
        return @{ Ok = $false; Reason = "'$linkPath' does not exist." }
    }
    $info = Get-LinkInfo $linkPath
    if ($null -eq $info -or -not $info.IsLink) {
        return @{ Ok = $false; Reason = "'$linkPath' is not a link." }
    }
    $indexJs = Join-Path $linkPath "dist\index.js"
    if (-not [System.IO.File]::Exists($indexJs)) {
        return @{ Ok = $false; Reason = "'$indexJs' is missing (run 'npm run build' in the source tree)" }
    }
    $indexDts = Join-Path $linkPath "dist\index.d.ts"
    if (-not [System.IO.File]::Exists($indexDts)) {
        return @{ Ok = $false; Reason = "'$indexDts' is missing (check tsconfig.build.json: declaration must be true)" }
    }
    return @{ Ok = $true; Reason = "OK" }
}

function Test-NodeCanRequire {
    param(
        [string]$StartFromDir,
        [string]$ModuleName = "lingofuse-ts"
    )
    Push-Location -LiteralPath $StartFromDir
    try {
        $script = @'
const mod = process.argv[1];
try { console.log(require.resolve(mod)); }
catch (e) { console.error('ERR: ' + e.message); process.exit(2); }
'@
        $out = & node -e $script $ModuleName 2>&1
        $rc = $LASTEXITCODE
    } finally {
        Pop-Location
    }
    return @{ Ok = ($rc -eq 0); Output = ("$out" -replace "`r`n", " | " -replace "`n", " | ") }
}

# ===========================================================================
# Main
# ===========================================================================

try {
    Write-Info "Install lingofuse-ts"

    if (-not (Get-Command npm  -ErrorAction SilentlyContinue)) { throw "npm is not on PATH." }
    if (-not (Get-Command node -ErrorAction SilentlyContinue)) { throw "node is not on PATH." }
    $nodeVersion = (& node -v 2>$null).Trim()
    Write-Info "  Node.js : $nodeVersion"
    Write-Info "  PSVer   : $($PSVersionTable.PSVersion)"

    $SourceDir = Resolve-SourceDir $SourceDir
    Write-Info "  Source  : $SourceDir"

    Write-Info "Checking dist/ ..."
    Initialize-Dist -TsDir $SourceDir

    $globalNM = (& npm root -g 2>$null).Trim()
    if ([string]::IsNullOrWhiteSpace($globalNM)) { throw "npm root -g returned an empty path." }
    $globalNM = [System.IO.Path]::GetFullPath($globalNM)
    Write-Info "  Global  : $globalNM"

    if (-not [System.IO.Directory]::Exists($globalNM)) {
        [void][System.IO.Directory]::CreateDirectory($globalNM)
    }

    $globalLink = Join-Path $globalNM "lingofuse-ts"
    Initialize-Junction -LinkPath $globalLink -TargetPath $SourceDir -ForceIt:$Force

    Write-Info "Updating USER NODE_PATH ..."
    Add-UserNodePathEntry $globalNM
    Sync-ProcessNodePathEntry $globalNM

    $projectLink   = $null
    $projectDirAbs = $null
    if (-not [string]::IsNullOrWhiteSpace($ProjectDir)) {
        $projectDirAbs = [System.IO.Path]::GetFullPath($ProjectDir)
        if (-not [System.IO.Directory]::Exists($projectDirAbs)) {
            throw "ProjectDir does not exist: $projectDirAbs"
        }
        Write-Info "  Project : $projectDirAbs"

        $projectLink = Join-Path (Join-Path $projectDirAbs "node_modules") "lingofuse-ts"
        Initialize-Junction -LinkPath $projectLink -TargetPath $SourceDir -ForceIt:$Force
    }

    if ($null -ne $projectLink) {
        Write-Info "Verifying project-local layout ..."
        $check = Test-PackageOnDisk -ProjectDir $projectDirAbs
        if (-not $check.Ok) { throw "Project-local verify failed: $($check.Reason)" }
        Write-Ok "  Layout OK: dist/index.js and dist/index.d.ts reachable."

        if (-not $SkipVerify) {
            Write-Info "Verifying Node can resolve from '$projectDirAbs' ..."
            $r = Test-NodeCanRequire -StartFromDir $projectDirAbs
            if (-not $r.Ok) {
                Write-Warn "  Node could not require from that directory:"
                Write-Warn "    $($r.Output)"
                Write-Warn "  Not a failure. The junction is in place; tsc/tsx/bun/deno will find it."
            } else {
                Write-Ok "  Node resolve: $($r.Output)"
            }
        }
    } else {
        Write-Info "Verifying global layout ..."
        $check = Test-PackageOnDisk -ProjectDir $globalNM
        if (-not $check.Ok) { throw "Global verify failed: $($check.Reason)" }
        Write-Ok "  Layout OK: dist/index.js and dist/index.d.ts reachable."

        if (-not $SkipVerify) {
            Write-Info "Verifying Node can resolve from '$globalNM' ..."
            $r = Test-NodeCanRequire -StartFromDir $globalNM
            if (-not $r.Ok) {
                Write-Warn "  Global Node resolve failed: $($r.Output)"
                Write-Warn "  Not a failure. For tsc/bun/deno run with -ProjectDir."
            } else {
                Write-Ok "  Node resolve: $($r.Output)"
            }
        }
    }

    $pdValue = ""
    $pjValue = ""
    if ($null -ne $projectLink) {
        $pdValue = $ProjectDir
        $pjValue = $projectLink
    }
    $record = [ordered]@{
        Version           = 4
        InstalledAt       = (Get-Date).ToString("o")
        SourceDir         = $SourceDir
        GlobalNodeModules = $globalNM
        GlobalJunction    = $globalLink
        ProjectDir        = $pdValue
        ProjectJunction   = $pjValue
        NodeVersion       = $nodeVersion
    }
    $recordFile = Join-Path $globalNM "lingofuse-ts.install.json"
    $record | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $recordFile -Encoding UTF8
    Write-Ok "  Record: $recordFile"

    Write-Host ""
    Write-Ok "Install completed."
    if ($null -ne $projectLink) {
        Write-Info "  From '$ProjectDir\*.ts' you can now:"
        Write-Info "      import * as lf from 'lingofuse-ts';"
    } else {
        Write-Info "  For tsc/bun/deno run again with -ProjectDir."
    }
    Write-Info "  Uninstall: .\uninstall.ps1 [-ProjectDir <same-dir>]"
    exit 0

} catch {
    Write-Err $_.Exception.Message
    exit 1
}