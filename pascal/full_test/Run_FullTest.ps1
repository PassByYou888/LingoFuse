#Requires -Version 5.1
<#
 * =============================================================================
 * Run_FullTest.ps1 - LingoFuse full test automation
 * =============================================================================
 *
 * Orchestrates three test programs and produces a consolidated report:
 *
 *   1. LingoFuse_SelfTest     - foreground, hard timeout 120 s
 *   2. LingoFuse_ServerTest   - background, hard timeout 60 s
 *   3. LingoFuse_ClientTest   - foreground, hard timeout 300 s
 *
 * Both ServerTest and ClientTest support graceful shutdown via a sentinel
 * file. This script writes the sentinel after ClientTest finishes so that
 * ServerTest reports calls / notifies / errors in its log.
 *
 * Automation markers parsed from logs:
 *   [READY] <addr>        startup handshake
 *   [PASS] <test>         per-test success
 *   [FAIL] <test>         per-test failure
 *   [STATS] ...           periodic stats
 *   [SUMMARY] pass=... fail=... total=... uptime_ms=...
 *   [SHUTDOWN] reason=... shutdown reason
 *
 * Design notes:
 *   - Uses System.Diagnostics.Process directly (not Start-Process cmdlet).
 *   - No OutputDataReceived event handlers (they crash the PS host).
 *   - stdout / stderr drained via ReadToEndAsync().
 *   - Process wait uses polling on HasExited.
 *
 * Usage:
 *     .\Run_FullTest.ps1
 *     .\Run_FullTest.ps1 -SelfTimeout 60 -ClientTimeout 120 -ServerTimeout 30
 *     .\Run_FullTest.ps1 -SkipBuild
 *     .\Run_FullTest.ps1 -NoServer
 *
 * Exit codes:
 *     0 - all programs passed
 *     1 - one or more programs failed
 *     2 - preflight failure (missing exe)
 * =============================================================================
#>

#Requires -Version 5.1

[CmdletBinding()]
param(
    [int]$SelfTimeout   = 120,
    [int]$ServerTimeout = 60,
    [int]$ClientTimeout = 300,
    [switch]$SkipBuild,
    [switch]$NoServer,
    [switch]$KeepArtifacts
)

$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# Paths and global state
# ---------------------------------------------------------------------------

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
Set-Location -LiteralPath $scriptDir

$stamp     = Get-Date -Format 'yyyyMMdd_HHmmss'
$startTime = Get-Date

$selfExe   = Join-Path $scriptDir 'LingoFuse_SelfTest.exe'
$serverExe = Join-Path $scriptDir 'LingoFuse_ServerTest.exe'
$clientExe = Join-Path $scriptDir 'LingoFuse_ClientTest.exe'

$selfLog   = Join-Path $scriptDir 'LingoFuse_SelfTest.log'
$serverLog = Join-Path $scriptDir 'LingoFuse_ServerTest.log'
$clientLog = Join-Path $scriptDir 'LingoFuse_ClientTest.log'

$serverSentinel = Join-Path $scriptDir 'LingoFuse_ServerTest.exit'
$clientSentinel = Join-Path $scriptDir 'LingoFuse_ClientTest.exit'

$reportFile = Join-Path $scriptDir ("TestReport_{0}.txt" -f $stamp)

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

function Write-Step {
    param([string]$Msg, [string]$Color = 'Yellow')
    Write-Host ('[' + (Get-Date -Format 'HH:mm:ss') + '] ' + $Msg) -ForegroundColor $Color
}

function Write-OK   { param([string]$Msg) Write-Host ('[OK]   ' + $Msg) -ForegroundColor Green  }
function Write-Warn { param([string]$Msg) Write-Host ('[WARN] ' + $Msg) -ForegroundColor Yellow }
function Write-Err  { param([string]$Msg) Write-Host ('[ERR]  ' + $Msg) -ForegroundColor Red    }

function Assert-Exists {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) {
        throw "Required file not found: $Path"
    }
}

function Remove-IfExists {
    param([string]$Path)
    if (Test-Path -LiteralPath $Path) {
        Remove-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
    }
}

# ---------------------------------------------------------------------------
# Poll-based wait
# ---------------------------------------------------------------------------

function Wait-ProcessExit {
    param(
        [System.Diagnostics.Process]$Proc,
        [int]$TimeoutMs
    )
    $deadline = (Get-Date).AddMilliseconds($TimeoutMs)
    while ((Get-Date) -lt $deadline) {
        if ($Proc.HasExited) { return $true }
        Start-Sleep -Milliseconds 200
    }
    return $Proc.HasExited
}

# ---------------------------------------------------------------------------
# Low-level process launcher
# ---------------------------------------------------------------------------

function New-ProcInfo {
    param(
        [string]$ExePath,
        [string]$WorkingDir,
        [string[]]$ExtraArgs
    )
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName               = $ExePath
    $psi.WorkingDirectory       = $WorkingDir
    $psi.UseShellExecute        = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError  = $true
    $psi.CreateNoWindow         = $true
    if ($ExtraArgs) {
        foreach ($a in $ExtraArgs) {
            [void]$psi.ArgumentList.Add($a)
        }
    }
    return $psi
}

function Run-TestForeground {
    param(
        [string]$ExePath,
        [string]$WorkingDir,
        [string]$StdoutFile,
        [int]$TimeoutMs,
        [string[]]$ExtraArgs
    )

    $psi  = New-ProcInfo -ExePath $ExePath -WorkingDir $WorkingDir -ExtraArgs $ExtraArgs
    $proc = New-Object System.Diagnostics.Process
    $proc.StartInfo = $psi

    [void]$proc.Start()

    $stdoutTask = $proc.StandardOutput.ReadToEndAsync()
    $stderrTask = $proc.StandardError.ReadToEndAsync()

    $exited = Wait-ProcessExit -Proc $proc -TimeoutMs $TimeoutMs
    if (-not $exited) {
        try { $proc.Kill() } catch { }
        [void]$proc.WaitForExit(5000)
    }

    $out = ''
    $err = ''
    try { $out = $stdoutTask.Result } catch { }
    try { $err = $stderrTask.Result } catch { }

    if ($StdoutFile) {
        $combined = ''
        if ($out) { $combined += $out }
        if ($err) { $combined += "`r`n--- STDERR ---`r`n" + $err }
        Set-Content -LiteralPath $StdoutFile -Value $combined -Encoding UTF8
    }

    $code = -1
    try { $code = $proc.ExitCode } catch { }
    try { $proc.Dispose() } catch { }
    return $code
}

function Run-TestBackground {
    param(
        [string]$ExePath,
        [string]$WorkingDir,
        [string[]]$ExtraArgs
    )

    $psi  = New-ProcInfo -ExePath $ExePath -WorkingDir $WorkingDir -ExtraArgs $ExtraArgs
    $proc = New-Object System.Diagnostics.Process
    $proc.StartInfo = $psi

    [void]$proc.Start()

    [void]$proc.StandardOutput.ReadToEndAsync()
    [void]$proc.StandardError.ReadToEndAsync()

    return $proc
}

# ---------------------------------------------------------------------------
# Log parsers
# ---------------------------------------------------------------------------

function Parse-TestLog {
    param([string]$LogPath, [string]$Label)

    $r = [PSCustomObject]@{
        Label      = $Label
        LogPath    = $LogPath
        Exists     = $false
        PassCount  = 0
        FailCount  = 0
        TotalCount = 0
        PassLines  = @()
        FailLines  = @()
        ReadyLines = @()
        SummaryLine = ''
        ShutdownLine = ''
        StatsLines = @()
        SizeBytes  = 0
    }

    if (-not (Test-Path -LiteralPath $LogPath)) { return $r }

    $r.Exists    = $true
    $r.SizeBytes = (Get-Item -LiteralPath $LogPath).Length

    $lines = Get-Content -LiteralPath $LogPath -Encoding UTF8 -ErrorAction SilentlyContinue
    if ($null -eq $lines) { return $r }

    foreach ($ln in $lines) {
        if     ($ln -match '^\[PASS\]\s*(.*)$')     { $r.PassCount++; $r.PassLines += $Matches[1] }
        elseif ($ln -match '^\[FAIL\]\s*(.*)$')     { $r.FailCount++; $r.FailLines += $Matches[1] }
        elseif ($ln -match '^\[READY\]\s*(.*)$')    { $r.ReadyLines += $Matches[1] }
        elseif ($ln -match '^\[SUMMARY\]\s*(.*)$')  { $r.SummaryLine  = $Matches[1] }
        elseif ($ln -match '^\[SHUTDOWN\]\s*(.*)$') { $r.ShutdownLine = $Matches[1] }
        elseif ($ln -match '^\[STATS\]\s*(.*)$')    { $r.StatsLines += $Matches[1] }
    }

    $r.TotalCount = $r.PassCount + $r.FailCount
    return $r
}

function Extract-Reason {
    param([string]$Line)
    if ($Line -match 'reason=([^\s]+)') { return $Matches[1] }
    return ''
}

# ---------------------------------------------------------------------------
# Pre-flight
# ---------------------------------------------------------------------------

Write-Header 'LingoFuse Full Test Automation'

Write-Host ('Working dir    : ' + $scriptDir)
Write-Host ('Timestamp      : ' + $stamp)
Write-Host ('SelfTest       : ' + $selfExe)
Write-Host ('ServerTest     : ' + $serverExe)
Write-Host ('ClientTest     : ' + $clientExe)
Write-Host ('Self timeout   : ' + $SelfTimeout + ' s')
Write-Host ('Server timeout : ' + $ServerTimeout + ' s')
Write-Host ('Client timeout : ' + $ClientTimeout + ' s')
Write-Host ('Skip build     : ' + [bool]$SkipBuild)
Write-Host ('No server      : ' + [bool]$NoServer)
Write-Host ''

# ---------------------------------------------------------------------------
# Optional build step
# ---------------------------------------------------------------------------

if (-not $SkipBuild) {
    Write-Header 'Build stage'
    $buildScript = Join-Path $scriptDir 'build.ps1'
    if (Test-Path -LiteralPath $buildScript) {
        Write-Step 'Running build.ps1 ...'
        & $buildScript
        if ($LASTEXITCODE -ne 0) {
            Write-Err ('build.ps1 returned ' + $LASTEXITCODE)
            exit 2
        }
        Write-OK 'Build stage OK'
    } else {
        Write-Warn 'build.ps1 not found, skipping'
    }
}

Assert-Exists $selfExe
Assert-Exists $clientExe
if (-not $NoServer) {
    Assert-Exists $serverExe
}

Remove-IfExists $selfLog
Remove-IfExists $serverLog
Remove-IfExists $clientLog
Remove-IfExists $serverSentinel
Remove-IfExists $clientSentinel

# ---------------------------------------------------------------------------
# Stage 1 : SelfTest
# ---------------------------------------------------------------------------

Write-Header 'Stage 1 / 3  -  LingoFuse_SelfTest'

$selfStart = Get-Date
Write-Step ('Running SelfTest (foreground, hard timeout ' + $SelfTimeout + 's) ...')
$selfExit    = Run-TestForeground -ExePath $selfExe -WorkingDir $scriptDir `
                                  -StdoutFile (Join-Path $scriptDir 'LingoFuse_SelfTest.stdout.txt') `
                                  -TimeoutMs ($SelfTimeout * 1000)
$selfEnd     = Get-Date
$selfElapsed = ($selfEnd - $selfStart).TotalSeconds

if ($selfExit -eq 0) {
    Write-OK ('SelfTest finished in {0:N2} sec (exit 0)' -f $selfElapsed)
} else {
    Write-Warn ('SelfTest finished in {0:N2} sec (exit {1})' -f $selfElapsed, $selfExit)
}

# ---------------------------------------------------------------------------
# Stage 2 : ServerTest + ClientTest
# ---------------------------------------------------------------------------

$serverProc    = $null
$serverCrashed = $false
$serverStart   = Get-Date
$serverElapsed = 0.0
$clientElapsed = 0.0
$clientExit    = -1

if (-not $NoServer) {
    Write-Header 'Stage 2 / 3  -  ServerTest + ClientTest'

    Write-Step 'Starting ServerTest in background ...'
    $serverStart = Get-Date
    $serverProc  = Run-TestBackground -ExePath $serverExe -WorkingDir $scriptDir
    Write-OK ('ServerTest started (PID = {0})' -f $serverProc.Id)

    Write-Step 'Waiting 3 seconds for server to initialise ...'
    Start-Sleep -Seconds 3

    if ($serverProc.HasExited) {
        Write-Err ('ServerTest exited prematurely, code = {0}' -f $serverProc.ExitCode)
        $serverCrashed = $true
    } else {
        Write-OK 'ServerTest running'
    }

    if (-not $serverCrashed) {
        Write-Step ('Running ClientTest (foreground, hard timeout ' + $ClientTimeout + 's) ...')
        $clientStart = Get-Date
        $clientExit  = Run-TestForeground -ExePath $clientExe -WorkingDir $scriptDir `
                                          -StdoutFile (Join-Path $scriptDir 'LingoFuse_ClientTest.stdout.txt') `
                                          -TimeoutMs ($ClientTimeout * 1000)
        $clientEnd     = Get-Date
        $clientElapsed = ($clientEnd - $clientStart).TotalSeconds

        if ($clientExit -eq 0) {
            Write-OK ('ClientTest finished in {0:N2} sec (exit 0)' -f $clientElapsed)
        } else {
            Write-Warn ('ClientTest finished in {0:N2} sec (exit {1})' -f $clientElapsed, $clientExit)
        }
    } else {
        Write-Warn 'Skipping ClientTest because ServerTest failed to start.'
    }

    Write-Step 'Signalling ServerTest to shut down (sentinel file) ...'
    try {
        Set-Content -LiteralPath $serverSentinel -Value 'exit' -Encoding ASCII
        Write-OK 'Sentinel file written'
    } catch {
        Write-Warn ('Could not write sentinel: ' + $_.Exception.Message)
    }

    if (-not $serverProc.HasExited) {
        Write-Step ('Waiting up to ' + $ServerTimeout + 's for ServerTest to exit ...')
        $serverExited = Wait-ProcessExit -Proc $serverProc -TimeoutMs ($ServerTimeout * 1000)
        if (-not $serverExited) {
            Write-Warn 'ServerTest did not exit in time, forcing termination.'
            try { $serverProc.Kill() } catch { }
            [void]$serverProc.WaitForExit(5000)
        } else {
            Write-OK 'ServerTest exited gracefully'
        }
    } else {
        Write-OK 'ServerTest already exited'
    }
    $serverEnd     = Get-Date
    $serverElapsed = ($serverEnd - $serverStart).TotalSeconds
    try { $serverProc.Dispose() } catch { }

    Remove-IfExists $serverSentinel
} else {
    Write-Header 'Stage 2 / 3  -  ServerTest + ClientTest (skipped)'
    Write-Warn 'NoServer specified; only SelfTest will run.'
}

# ---------------------------------------------------------------------------
# Stage 3 : Result collection
# ---------------------------------------------------------------------------

Write-Header 'Stage 3 / 3  -  Result Collection'

$selfResult   = Parse-TestLog -LogPath $selfLog   -Label 'LingoFuse_SelfTest'
$serverResult = Parse-TestLog -LogPath $serverLog -Label 'LingoFuse_ServerTest'
$clientResult = Parse-TestLog -LogPath $clientLog -Label 'LingoFuse_ClientTest'

$totalPass = $selfResult.PassCount + $serverResult.PassCount + $clientResult.PassCount
$totalFail = $selfResult.FailCount + $serverResult.FailCount + $clientResult.FailCount
$totalAll  = $totalPass + $totalFail

if ($totalAll -eq 0)      { $overall = 'UNKNOWN'    }
elseif ($totalFail -eq 0) { $overall = 'ALL PASSED' }
else                      { $overall = 'SOME FAILED' }

# ---------------------------------------------------------------------------
# Build the consolidated report
# ---------------------------------------------------------------------------

$report = New-Object System.Text.StringBuilder

[void]$report.AppendLine('=' * 60)
[void]$report.AppendLine('  LingoFuse Full Test Report')
[void]$report.AppendLine('=' * 60)
[void]$report.AppendLine(('Generated   : ' + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')))
[void]$report.AppendLine(('Start time  : ' + $startTime.ToString('yyyy-MM-dd HH:mm:ss')))
[void]$report.AppendLine(('Working dir : ' + $scriptDir))
[void]$report.AppendLine('')
[void]$report.AppendLine(('OVERALL     : ' + $overall))
[void]$report.AppendLine(('TOTAL PASS  : ' + $totalPass))
[void]$report.AppendLine(('TOTAL FAIL  : ' + $totalFail))
[void]$report.AppendLine(('TOTAL CHECK : ' + $totalAll))
[void]$report.AppendLine('')

$perProg = @(
    [PSCustomObject]@{ Name='SelfTest';   Res=$selfResult;   Elapsed=$selfElapsed;   Exe='LingoFuse_SelfTest.exe';   Log='LingoFuse_SelfTest.log'   }
    [PSCustomObject]@{ Name='ServerTest'; Res=$serverResult; Elapsed=$serverElapsed; Exe='LingoFuse_ServerTest.exe'; Log='LingoFuse_ServerTest.log' }
    [PSCustomObject]@{ Name='ClientTest'; Res=$clientResult; Elapsed=$clientElapsed; Exe='LingoFuse_ClientTest.exe'; Log='LingoFuse_ClientTest.log' }
)

[void]$report.AppendLine('-' * 60)
[void]$report.AppendLine('  Per-program breakdown')
[void]$report.AppendLine('-' * 60)
foreach ($p in $perProg) {
    $r = $p.Res
    [void]$report.AppendLine(('Program    : ' + $p.Name))
    [void]$report.AppendLine(('  Executable : ' + $p.Exe))
    [void]$report.AppendLine(('  Log file   : ' + $p.Log))
    [void]$report.AppendLine(('  Elapsed    : {0:N2} sec' -f $p.Elapsed))
    if (-not $r.Exists) {
        [void]$report.AppendLine('  STATUS     : LOG FILE MISSING')
    } else {
        [void]$report.AppendLine(('  Log size   : {0} bytes' -f $r.SizeBytes))
        [void]$report.AppendLine(('  PASS       : {0}' -f $r.PassCount))
        [void]$report.AppendLine(('  FAIL       : {0}' -f $r.FailCount))
        [void]$report.AppendLine(('  TOTAL      : {0}' -f $r.TotalCount))
        if ($r.ReadyLines.Count -gt 0) {
            foreach ($rd in $r.ReadyLines) {
                [void]$report.AppendLine(('  READY      : ' + $rd))
            }
        }
        if ($r.SummaryLine -ne '') {
            [void]$report.AppendLine(('  SUMMARY    : ' + $r.SummaryLine))
        }
        if ($r.ShutdownLine -ne '') {
            [void]$report.AppendLine(('  SHUTDOWN   : ' + $r.ShutdownLine))
        }
    }
    [void]$report.AppendLine('')
}

if ($totalFail -gt 0) {
    [void]$report.AppendLine('-' * 60)
    [void]$report.AppendLine('  Failure details')
    [void]$report.AppendLine('-' * 60)
    foreach ($p in $perProg) {
        $r = $p.Res
        if ($r.FailCount -gt 0) {
            [void]$report.AppendLine(('[{0}] {1} failure(s):' -f $p.Name, $r.FailCount))
            foreach ($f in $r.FailLines) {
                [void]$report.AppendLine('  [FAIL] ' + $f)
            }
            [void]$report.AppendLine('')
        }
    }
}

[void]$report.AppendLine('-' * 60)
[void]$report.AppendLine('  Pass details')
[void]$report.AppendLine('-' * 60)
foreach ($p in $perProg) {
    $r = $p.Res
    if ($r.PassCount -gt 0) {
        [void]$report.AppendLine(('[{0}] {1} pass(es):' -f $p.Name, $r.PassCount))
        foreach ($s in $r.PassLines) {
            [void]$report.AppendLine('  [PASS] ' + $s)
        }
        [void]$report.AppendLine('')
    }
}

[void]$report.AppendLine('-' * 60)
[void]$report.AppendLine('  Artifacts')
[void]$report.AppendLine('-' * 60)
foreach ($p in $perProg) {
    if ($p.Res.Exists) {
        [void]$report.AppendLine('  ' + $p.Res.LogPath)
    }
}
[void]$report.AppendLine('')
[void]$report.AppendLine('=' * 60)
[void]$report.AppendLine('  End of report')
[void]$report.AppendLine('=' * 60)

Set-Content -LiteralPath $reportFile -Value $report.ToString() -Encoding UTF8

# ---------------------------------------------------------------------------
# Final console summary
# ---------------------------------------------------------------------------

Write-Header 'TEST SUMMARY'

$color = switch ($overall) {
    'ALL PASSED'  { 'Green'  }
    'SOME FAILED' { 'Red'    }
    default       { 'Yellow' }
}

Write-Host ('  Overall : ' + $overall) -ForegroundColor $color
Write-Host ('  Passed  : ' + $totalPass)
Write-Host ('  Failed  : ' + $totalFail)
Write-Host ('  Total   : ' + $totalAll)
Write-Host ''
Write-Host '  Per program:' -ForegroundColor Cyan
foreach ($p in $perProg) {
    $r = $p.Res
    $c = if ($r.FailCount -gt 0) { 'Red' } elseif (-not $r.Exists) { 'DarkGray' } else { 'Green' }
    if ($r.Exists) {
        Write-Host ('    {0,-12} PASS={1,-5} FAIL={2,-5} TIME={3,8:N2}s' -f `
            $p.Name, $r.PassCount, $r.FailCount, $p.Elapsed) -ForegroundColor $c
    } else {
        Write-Host ('    {0,-12} (log not found)' -f $p.Name) -ForegroundColor DarkGray
    }
}
Write-Host ''
Write-Host '  Log files:' -ForegroundColor Cyan
foreach ($p in $perProg) {
    if ($p.Res.Exists) {
        Write-Host ('    ' + $p.Res.LogPath) -ForegroundColor DarkGray
    }
}
Write-Host ''
Write-Host ('  Report  : ' + $reportFile) -ForegroundColor Green
Write-Host ''

# ---------------------------------------------------------------------------
# Exit code
# ---------------------------------------------------------------------------

if ($totalFail -gt 0) {
    exit 1
}
if ($totalAll -eq 0) {
    exit 1
}
if (-not $NoServer -and $clientExit -ne 0 -and $clientExit -ne -1) {
    exit 1
}
exit 0