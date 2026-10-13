#Requires -Version 5.1
<#
 * =============================================================================
 * clean.ps1 - Remove build artifacts and test outputs
 * =============================================================================
 *
 * Removes:
 *     - Compiled executables  (*.exe)
 *     - Compiler intermediates (*.o, *.ppu, *.a, *.res, *.or)
 *     - Lazarus backup files   (*.lps.bak, *.lpi.bak, *.lpk.bak)
 *     - Test outputs           (*.log, *.stdout.txt)
 *     - Consolidated reports   (TestReport_*.txt)
 *     - Server sentinel files  (*.exit)
 *     - Lazarus build dirs     (backup/, lib/, units/)
 *
 * Does NOT remove sources (.lpr, .lpi, .pas, .inc, .ps1, .md).
 *
 * Usage:
 *     .\clean.ps1
 *     .\clean.ps1 -DryRun
 *     .\clean.ps1 -KeepReports
 *     .\clean.ps1 -All          # also remove reports and Lazarus metadata
 *
 * Exit codes:
 *     0 - always (informational)
 * =============================================================================
#>

[CmdletBinding()]
param(
    [switch]$DryRun,
    [switch]$KeepReports,
    [switch]$All
)

$ErrorActionPreference = 'Continue'

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
Set-Location -LiteralPath $scriptDir

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
function Write-Info { param([string]$M) Write-Host ('[INFO] ' + $M) -ForegroundColor Gray  }

# ---------------------------------------------------------------------------
# Removal helper
# ---------------------------------------------------------------------------

$script:RemovedFiles = 0
$script:RemovedDirs  = 0
$script:TotalBytes   = 0

function Remove-ItemSafe {
    param(
        [string]$Path,
        [switch]$IsDirectory
    )
    if (-not (Test-Path -LiteralPath $Path)) { return }

    if ($DryRun) {
        if ($IsDirectory) {
            Write-Info ('would remove dir : ' + $Path)
        } else {
            $sz = (Get-Item -LiteralPath $Path -ErrorAction SilentlyContinue).Length
            Write-Info ('would remove file: ' + $Path + '  (' + $sz + ' bytes)')
        }
        return
    }

    try {
        if ($IsDirectory) {
            Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction Stop
            $script:RemovedDirs++
            Write-Info ('removed dir : ' + $Path)
        } else {
            $sz = (Get-Item -LiteralPath $Path -ErrorAction SilentlyContinue).Length
            Remove-Item -LiteralPath $Path -Force -ErrorAction Stop
            $script:RemovedFiles++
            $script:TotalBytes += $sz
            Write-Info ('removed file: ' + $Path)
        }
    } catch {
        Write-Warn ('failed to remove: ' + $Path + '  (' + $_.Exception.Message + ')')
    }
}

function Remove-ByPattern {
    param([string]$Pattern)
    $files = Get-ChildItem -LiteralPath $scriptDir -Filter $Pattern -File -ErrorAction SilentlyContinue
    foreach ($f in $files) {
        Remove-ItemSafe -Path $f.FullName
    }
}

# ---------------------------------------------------------------------------
# Pre-flight
# ---------------------------------------------------------------------------

Write-Header 'LingoFuse full_test - Clean'

Write-Host ('Working dir : ' + $scriptDir)
Write-Host ('Dry run     : ' + $DryRun)
Write-Host ('Keep reports: ' + $KeepReports)
Write-Host ('All         : ' + $All)
Write-Host ''

# ---------------------------------------------------------------------------
# Executables
# ---------------------------------------------------------------------------

Write-Header 'Compiled executables'

$exeList = @(
    'LingoFuse_SelfTest.exe',
    'LingoFuse_ServerTest.exe',
    'LingoFuse_ClientTest.exe'
)
foreach ($f in $exeList) {
    Remove-ItemSafe -Path (Join-Path $scriptDir $f)
}

# ---------------------------------------------------------------------------
# Compiler intermediates
# ---------------------------------------------------------------------------

Write-Header 'Compiler intermediates'

$intermediatePatterns = @('*.o', '*.ppu', '*.a', '*.res', '*.or', '*.compiled')
foreach ($pat in $intermediatePatterns) {
    Remove-ByPattern -Pattern $pat
}

# ---------------------------------------------------------------------------
# Lazarus metadata
# ---------------------------------------------------------------------------

if ($All) {
    Write-Header 'Lazarus metadata'

    $lazarusPatterns = @('*.lps.bak', '*.lpi.bak', '*.lpk.bak', '*.lpr.bak')
    foreach ($pat in $lazarusPatterns) {
        Remove-ByPattern -Pattern $pat
    }

    $lazarusDirs = @('backup', 'lib', 'units')
    foreach ($d in $lazarusDirs) {
        $p = Join-Path $scriptDir $d
        if (Test-Path -LiteralPath $p) {
            Remove-ItemSafe -Path $p -IsDirectory
        }
    }
} else {
    Write-Header 'Lazarus metadata (skipped)'
    Write-Info 'use -All to remove backup/, lib/, units/ and *.bak'
}

# ---------------------------------------------------------------------------
# Test output logs
# ---------------------------------------------------------------------------

Write-Header 'Test output logs'

$logFiles = @(
    'LingoFuse_SelfTest.log',
    'LingoFuse_ServerTest.log',
    'LingoFuse_ClientTest.log',
    'LingoFuse_SelfTest.stdout.txt',
    'LingoFuse_ServerTest.stdout.txt',
    'LingoFuse_ClientTest.stdout.txt',
    'LingoFuse_ServerTest.exit',
    'LingoFuse_ClientTest.exit'
)
foreach ($f in $logFiles) {
    Remove-ItemSafe -Path (Join-Path $scriptDir $f)
}

Remove-ByPattern -Pattern 'build_*.log'
Remove-ByPattern -Pattern '*.exit'

# ---------------------------------------------------------------------------
# Consolidated reports
# ---------------------------------------------------------------------------

if (-not $KeepReports -and $All) {
    Write-Header 'Consolidated reports'
    Remove-ByPattern -Pattern 'TestReport_*.txt'
} elseif (-not $KeepReports) {
    Write-Header 'Consolidated reports (skipped)'
    Write-Info 'use -All to also remove TestReport_*.txt'
} else {
    Write-Header 'Consolidated reports (kept)'
    $reports = Get-ChildItem -LiteralPath $scriptDir -Filter 'TestReport_*.txt' -File -ErrorAction SilentlyContinue
    if ($reports) {
        foreach ($f in $reports) {
            Write-Info ('kept: ' + $f.Name)
        }
    } else {
        Write-Info 'no report files found'
    }
}

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------

Write-Header 'Summary'

if ($DryRun) {
    Write-Host '  Dry run - nothing was actually removed.' -ForegroundColor Yellow
} else {
    Write-Host ('  Files removed : ' + $script:RemovedFiles) -ForegroundColor Cyan
    Write-Host ('  Dirs removed  : ' + $script:RemovedDirs)  -ForegroundColor Cyan
    Write-Host ('  Bytes freed   : ' + $script:TotalBytes)   -ForegroundColor Cyan
}
Write-Host ''

exit 0