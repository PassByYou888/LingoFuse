#Requires -Version 5.1
<#
 * =============================================================================
 * build.ps1 - LingoFuse full_test build orchestrator
 * =============================================================================
 *
 * Builds the three Lazarus projects used by the LingoFuse test suite:
 *     LingoFuse_SelfTest.lpi
 *     LingoFuse_ServerTest.lpi
 *     LingoFuse_ClientTest.lpi
 *
 * - Locates lazbuild via PATH or common install paths.
 * - Builds each project independently (one failure does not stop the others).
 * - Verifies .exe artifacts after the build.
 * - Writes a build log next to the script.
 *
 * Usage:
 *     .\build.ps1
 *     .\build.ps1 -Lazbuild 'C:\lazarus\lazbuild.exe'
 *     .\build.ps1 -Clean
 *     .\build.ps1 -Rebuild
 *
 * Exit codes:
 *     0 - all projects built, all artifacts present
 *     1 - one or more build failures, or missing artifact
 *     2 - lazbuild not found
 * =============================================================================
#>

[CmdletBinding()]
param(
    [string]$Lazbuild,
    [switch]$Clean,
    [switch]$Rebuild
)

$ErrorActionPreference = 'Stop'

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
Set-Location -LiteralPath $scriptDir

$stamp     = Get-Date -Format 'yyyyMMdd_HHmmss'
$buildLog  = Join-Path $scriptDir ("build_{0}.log" -f $stamp)
$startTime = Get-Date

# ---------------------------------------------------------------------------
# Console helpers
# ---------------------------------------------------------------------------

function Write-Header {
    param([string]$Msg)
    Write-Host ''
    Write-Host ('=' * 60) -ForegroundColor Cyan
    Write-Host ('  ' + $Msg) -ForegroundColor Cyan
    Write-Host ('=' * 60) -ForegroundColor Cyan
}

function Write-Step { param([string]$M) Write-Host ('[..]  ' + $M) -ForegroundColor Yellow }
function Write-OK   { param([string]$M) Write-Host ('[OK]  ' + $M) -ForegroundColor Green  }
function Write-Warn { param([string]$M) Write-Host ('[WARN] ' + $M) -ForegroundColor Yellow }
function Write-Err  { param([string]$M) Write-Host ('[ERR] ' + $M) -ForegroundColor Red    }

function Write-Log {
    param([string]$M)
    Add-Content -LiteralPath $buildLog -Value $M -Encoding UTF8
}

# ---------------------------------------------------------------------------
# Locate lazbuild
# ---------------------------------------------------------------------------

function Find-Lazbuild {
    param([string]$Explicit)

    if ($Explicit) {
        if (Test-Path -LiteralPath $Explicit) {
            return (Resolve-Path -LiteralPath $Explicit).Path
        }
        throw "Specified lazbuild not found: $Explicit"
    }

    $cmd = Get-Command lazbuild -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }

    $candidates = @(
        'C:\lazarus\lazbuild.exe',
        'C:\Lazarus\lazbuild.exe',
        'C:\tools\lazarus\lazbuild.exe',
        'D:\lazarus\lazbuild.exe',
        'D:\Lazarus\lazbuild.exe',
        'D:\tools\lazarus\lazbuild.exe',
        "$env:LOCALAPPDATA\lazarus\lazbuild.exe",
        "$env:ProgramFiles\Lazarus\lazbuild.exe",
        "${env:ProgramFiles(x86)}\Lazarus\lazbuild.exe"
    )
    foreach ($c in $candidates) {
        if ($c -and (Test-Path -LiteralPath $c)) { return $c }
    }
    return $null
}

# ---------------------------------------------------------------------------
# Run lazbuild (uses ProcessStartInfo; no event handlers)
# ---------------------------------------------------------------------------

function Invoke-Lazbuild {
    param(
        [string]$LazbuildExe,
        [string]$ProjectFile,
        [string[]]$ExtraArgs
    )

    $args = @()
    if ($ExtraArgs) { $args += $ExtraArgs }
    $args += $ProjectFile

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName               = $LazbuildExe
    $psi.WorkingDirectory       = $scriptDir
    $psi.UseShellExecute        = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError  = $true
    $psi.CreateNoWindow         = $true
    foreach ($a in $args) {
        [void]$psi.ArgumentList.Add($a)
    }

    $proc = New-Object System.Diagnostics.Process
    $proc.StartInfo = $psi

    Write-Log ('COMMAND: ' + $LazbuildExe + ' ' + ($args -join ' '))

    [void]$proc.Start()
    $stdoutTask = $proc.StandardOutput.ReadToEndAsync()
    $stderrTask = $proc.StandardError.ReadToEndAsync()
    $proc.WaitForExit()

    $out = ''
    $err = ''
    try { $out = $stdoutTask.Result } catch { }
    try { $err = $stderrTask.Result } catch { }

    if ($out) { Write-Log $out }
    if ($err) { Write-Log '--- STDERR ---'; Write-Log $err }

    $code = -1
    try { $code = $proc.ExitCode } catch { }
    try { $proc.Dispose() } catch { }

    return @{ ExitCode = $code; Stdout = $out; Stderr = $err }
}

# ---------------------------------------------------------------------------
# Pre-flight
# ---------------------------------------------------------------------------

Write-Header 'LingoFuse full_test - Build'

Write-Host ('Working dir : ' + $scriptDir)
Write-Host ('Timestamp   : ' + $stamp)
Write-Host ('Build log   : ' + $buildLog)
Write-Host ('Clean       : ' + [bool]$Clean)
Write-Host ('Rebuild     : ' + [bool]$Rebuild)
Write-Host ''

Write-Log ('BUILD START: ' + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))
Write-Log ('Working dir: ' + $scriptDir)

$lazbuildExe = Find-Lazbuild -Explicit $Lazbuild
if (-not $lazbuildExe) {
    Write-Err 'lazbuild not found.'
    Write-Host ''
    Write-Host '  lazbuild is part of the Lazarus IDE. Install Lazarus, or'
    Write-Host '  pass the executable path explicitly:'
    Write-Host '      .\build.ps1 -Lazbuild ''C:\lazarus\lazbuild.exe'''
    Write-Log 'ERROR: lazbuild not found'
    exit 2
}
Write-OK ('lazbuild: ' + $lazbuildExe)
Write-Log ('lazbuild: ' + $lazbuildExe)

$projects = @(
    @{ Name = 'SelfTest';   File = 'LingoFuse_SelfTest.lpi';   Exe = 'LingoFuse_SelfTest.exe'   },
    @{ Name = 'ServerTest'; File = 'LingoFuse_ServerTest.lpi'; Exe = 'LingoFuse_ServerTest.exe' },
    @{ Name = 'ClientTest'; File = 'LingoFuse_ClientTest.lpi'; Exe = 'LingoFuse_ClientTest.exe' }
)

foreach ($p in $projects) {
    if (-not (Test-Path -LiteralPath $p.File)) {
        Write-Err ('project file missing: ' + $p.File)
        Write-Log ('ERROR: project file missing: ' + $p.File)
        exit 1
    }
}

# ---------------------------------------------------------------------------
# Optional clean
# ---------------------------------------------------------------------------

if ($Clean) {
    Write-Header 'Clean'
    foreach ($p in $projects) {
        Write-Step ('cleaning ' + $p.Name)
        $r = Invoke-Lazbuild -LazbuildExe $lazbuildExe -ProjectFile $p.File `
                             -ExtraArgs @('--build-mode=Default', 'clean')
        if ($r.ExitCode -ne 0) {
            Write-Warn ('clean returned exit ' + $r.ExitCode + ' for ' + $p.Name)
        } else {
            Write-OK ('clean ' + $p.Name)
        }
    }
}

# ---------------------------------------------------------------------------
# Build
# ---------------------------------------------------------------------------

Write-Header 'Build'

$results = @()
foreach ($p in $projects) {
    Write-Step ('building ' + $p.Name + ' (' + $p.File + ')')
    Write-Log ''
    Write-Log ('### BUILD ' + $p.Name)

    $t0 = Get-Date
    $extraArgs = @()
    if ($Rebuild) { $extraArgs = @('--build-all') }

    $r = Invoke-Lazbuild -LazbuildExe $lazbuildExe -ProjectFile $p.File -ExtraArgs $extraArgs
    $dt = ((Get-Date) - $t0).TotalSeconds

    if ($r.ExitCode -eq 0) {
        Write-OK ('{0} built in {1:N2}s' -f $p.Name, $dt)
    } else {
        Write-Err ('{0} FAILED in {1:N2}s (exit {2})' -f $p.Name, $dt, $r.ExitCode)
        if ($r.Stderr) {
            Write-Host ('    stderr: ' + $r.Stderr.Split("`n")[0])
        }
    }
    Write-Log ('exit={0} elapsed={1:N2}s' -f $r.ExitCode, $dt)

    $results += [PSCustomObject]@{
        Name     = $p.Name
        ExitCode = $r.ExitCode
        Elapsed  = $dt
        Exe      = $p.Exe
    }
}

# ---------------------------------------------------------------------------
# Verify artifacts
# ---------------------------------------------------------------------------

Write-Header 'Artifact Check'

$missing = @()
foreach ($p in $projects) {
    if (Test-Path -LiteralPath $p.Exe) {
        $info = Get-Item -LiteralPath $p.Exe
        Write-OK ('{0}  ({1:N0} bytes)' -f $p.Exe, $info.Length)
        Write-Log ('artifact OK: {0} ({1} bytes)' -f $p.Exe, $info.Length)
    } else {
        Write-Warn ('missing: ' + $p.Exe)
        Write-Log ('artifact MISSING: ' + $p.Exe)
        $missing += $p.Exe
    }
}

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------

Write-Header 'Summary'

$failed = @($results | Where-Object { $_.ExitCode -ne 0 })
$totalTime = ((Get-Date) - $startTime).TotalSeconds

foreach ($r in $results) {
    $c = if ($r.ExitCode -eq 0) { 'Green' } else { 'Red' }
    Write-Host ('  {0,-12} exit={1,-4} time={2,8:N2}s' -f $r.Name, $r.ExitCode, $r.Elapsed) -ForegroundColor $c
}
Write-Host ''
Write-Host ('  Total elapsed: {0:N2}s' -f $totalTime) -ForegroundColor Cyan
Write-Host ('  Build log    : ' + $buildLog) -ForegroundColor Cyan
Write-Host ''

Write-Log ''
Write-Log ('TOTAL ELAPSED: {0:N2}s' -f $totalTime)

if ($failed.Count -gt 0 -or $missing.Count -gt 0) {
    Write-Err ('{0} project(s) failed, {1} artifact(s) missing.' -f $failed.Count, $missing.Count)
    exit 1
}

Write-OK 'All projects built successfully.'
exit 0