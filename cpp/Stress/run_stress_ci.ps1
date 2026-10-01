# =============================================================================
#  run_stress_ci.ps1
# -----------------------------------------------------------------------------
#  One-shot CI orchestration + self-evaluation harness for the LingoFuse
#  stress suite on Windows.
#
#  WHAT IT DOES
#  ------------
#  Rather than running a single mixed workload, this script runs a SET of
#  comparison scenarios that together characterise the throughput of the
#  LingoFuse Call and Notify paths. Each scenario is independent, and the
#  final summary shows the numbers side by side so the operator can draw
#  their own conclusions.
#
#  The scenario set is:
#
#      1. Pure Notify throughput (32 threads, 20 msg/loop)
#      2. Pure Call @  32 threads
#      3. Pure Call @ 128 threads
#      4. Pure Call @ 512 threads
#      5. Mixed workload, 20 notify + 1 call per loop, 64 threads
#
#  WHY THIS DESIGN
#  ---------------
#  Call is synchronous: a worker thread that has issued a Call cannot do
#  anything else until the response returns. Call throughput therefore
#  scales with thread count, up to the server's saturation point.
#
#  Notify is fire-and-forget: one thread dispatches messages back-to-back.
#  Notify throughput scales with the dispatch rate, not with thread count.
#
#  The two paths saturate at very different levels. The comparison table
#  produced by this script quantifies that difference with real numbers.
#
#  USAGE
#  -----
#      .\run_stress_ci.ps1
#      .\run_stress_ci.ps1 -NotifyDuration 20 -CallDuration 20
#      .\run_stress_ci.ps1 -SkipMixed
#      .\run_stress_ci.ps1 -Quiet
#
#  EXIT CODES
#  ----------
#      0  all scenarios PASS
#      1  at least one scenario FAIL
#      2  startup error (missing exe, missing runtime library, ...)
# =============================================================================

param(
    [int]    $NotifyDuration = 15,
    [int]    $CallDuration   = 15,
    [int]    $MixedDuration  = 30,
    [switch] $SkipMixed,
    [switch] $SkipCallScaling,
    [switch] $Quiet
)

$ErrorActionPreference = "Stop"

# ---- 1. Locate the Binary directory ----------------------------------------
#  The script may live in the Binary directory itself, in cpp/Stress, or
#  anywhere else. Search the usual relative locations for StressService.exe.

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path

$Candidates = @(
    $ScriptDir,
    (Join-Path $ScriptDir "..\..\Binary"),
    (Join-Path $ScriptDir "..\Binary"),
    (Join-Path $ScriptDir "Binary")
)

$Bin = $null
foreach ($c in $Candidates) {
    if (-not (Test-Path $c)) { continue }
    $resolved = (Resolve-Path $c).Path
    if (Test-Path (Join-Path $resolved "StressService.exe")) {
        $Bin = $resolved
        break
    }
}

if (-not $Bin) {
    Write-Host "Could not locate StressService.exe. Searched:" -ForegroundColor Red
    foreach ($c in $Candidates) {
        Write-Host "    $c" -ForegroundColor Red
    }
    Write-Host ""
    Write-Host "Build the project first:" -ForegroundColor Yellow
    Write-Host "    cd LingoFuse\cpp; mkdir build; cd build" -ForegroundColor Yellow
    Write-Host "    cmake .. -DCMAKE_BUILD_TYPE=Release" -ForegroundColor Yellow
    Write-Host "    cmake --build . --config Release" -ForegroundColor Yellow
    exit 2
}

$Service = Join-Path $Bin "StressService.exe"
$Client  = Join-Path $Bin "StressClient.exe"
$Monitor = Join-Path $Bin "StressMonitor.exe"

foreach ($f in @($Service, $Client, $Monitor)) {
    if (-not (Test-Path $f)) {
        Write-Host "Missing executable: $f" -ForegroundColor Red
        exit 2
    }
}

# ---- 2. Scenario definitions ------------------------------------------------
#  Each scenario is a hashtable. The runner below is generic.

$Scenarios = @()

# Scenario 1: pure Notify throughput.
$Scenarios += @{
    Name          = "Notify-throughput"
    Title         = "Pure Notify throughput"
    Description   = "32 threads, 20 notify per loop, no Call"
    Duration      = $NotifyDuration
    Threads       = 32
    NotifyPerLoop = 20
    CallPerLoop   = 0
    Emphasis      = "measures the fire-and-forget Notify path"
}

# Scenarios 2-4: pure Call at increasing thread counts.
if (-not $SkipCallScaling) {
    foreach ($t in @(32, 128, 512)) {
        $Scenarios += @{
            Name          = "Call-$t"
            Title         = "Pure Call at $t threads"
            Description   = "$t threads, 1 call per loop, no Notify"
            Duration      = $CallDuration
            Threads       = $t
            NotifyPerLoop = 0
            CallPerLoop   = 1
            Emphasis      = "measures Call throughput and its thread scaling"
        }
    }
}

# Scenario 5: mixed workload, matching the historic default shape.
if (-not $SkipMixed) {
    $Scenarios += @{
        Name          = "Mixed-20-1"
        Title         = "Mixed 20:1 at 64 threads"
        Description   = "64 threads, 20 notify + 1 call per loop"
        Duration      = $MixedDuration
        Threads       = 64
        NotifyPerLoop = 20
        CallPerLoop   = 1
        Emphasis      = "measures the cost of sharing a worker between the two paths"
    }
}

if ($Scenarios.Count -eq 0) {
    Write-Host "No scenarios selected. Remove -SkipMixed / -SkipCallScaling." -ForegroundColor Red
    exit 2
}

# ---- 3. Compute total runtime for the service and monitor lifetimes --------
$TotalScenarioSeconds = 0
foreach ($s in $Scenarios) {
    # +3 s gap between scenarios so the previous client's handles can drain
    $TotalScenarioSeconds += $s.Duration + 3
}

$ServiceShutdownAfter = $TotalScenarioSeconds + 30
$MonitorDuration      = $TotalScenarioSeconds + 5

# ---- 4. Output file paths --------------------------------------------------
$Report      = Join-Path $ScriptDir "stress_ci_combined.jsonl"
$SummaryFile = Join-Path $ScriptDir "stress_ci_summary.txt"
$ServiceLog  = Join-Path $ScriptDir "stress_ci_service.jsonl"
$MonitorLog  = Join-Path $ScriptDir "stress_ci_monitor.jsonl"

foreach ($f in @($Report, $SummaryFile, $ServiceLog, $MonitorLog)) {
    if (Test-Path $f) { Remove-Item $f -Force }
}

# ---- 5. Banner -------------------------------------------------------------
Write-Host ""
Write-Host "======================================================================" -ForegroundColor Cyan
Write-Host "  LingoFuse Stress -- Self-Evaluation Harness" -ForegroundColor Cyan
Write-Host "======================================================================" -ForegroundColor Cyan
Write-Host ("  Binary directory   : {0}" -f $Bin)
Write-Host ("  Scenarios          : {0}" -f $Scenarios.Count)
Write-Host ("  Estimated runtime  : ~{0}s" -f $TotalScenarioSeconds)
Write-Host ""
Write-Host "  Scenario list:"
foreach ($s in $Scenarios) {
    Write-Host ("    - {0,-22} {1}" -f $s.Name, $s.Description)
}
Write-Host ""
Write-Host ("  Combined report    : {0}" -f $Report)
Write-Host ("  Summary report     : {0}" -f $SummaryFile)
Write-Host "======================================================================" -ForegroundColor Cyan

# ---- 6. Cleanup helper -----------------------------------------------------
#  Used in the finally block so that an early exit (or Ctrl+C) still
#  stops the child processes.

$ServiceProc = $null
$MonitorProc = $null

function Stop-ChildProcesses {
    if ($null -ne $script:ServiceProc) {
        try {
            if (-not $script:ServiceProc.HasExited) {
                $script:ServiceProc.Kill()
            }
        } catch {}
    }
    if ($null -ne $script:MonitorProc) {
        try {
            if (-not $script:MonitorProc.HasExited) {
                $script:MonitorProc.Kill()
            }
        } catch {}
    }
    # Best-effort cleanup of any stray stress executables.
    Get-Process StressService, StressMonitor, StressClient `
        -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
}

# ---- 7. Helper: run one scenario -------------------------------------------
#  Returns a hashtable with: LogFile, ExitCode, Summary (parsed JSON or $null)

function Invoke-Scenario {
    param(
        [hashtable] $Scenario,
        [string]    $ClientExe,
        [string]    $OutputDir,
        [switch]    $Silent
    )

    Write-Host ""
    Write-Host "======================================================================" -ForegroundColor Yellow
    Write-Host ("  Scenario: {0}" -f $Scenario.Title) -ForegroundColor Yellow
    Write-Host ("  {0}" -f $Scenario.Description) -ForegroundColor Yellow
    Write-Host ("  ({0})" -f $Scenario.Emphasis) -ForegroundColor DarkGray
    Write-Host "======================================================================" -ForegroundColor Yellow

    $logFile = Join-Path $OutputDir ("stress_ci_client_{0}.jsonl" -f $Scenario.Name)
    if (Test-Path $logFile) { Remove-Item $logFile -Force }

    $args = @(
        "--ci",
        "--duration",        "$($Scenario.Duration)",
        "--threads",         "$($Scenario.Threads)",
        "--notify-per-loop", "$($Scenario.NotifyPerLoop)",
        "--call-per-loop",   "$($Scenario.CallPerLoop)"
    )

    # PS 7.3+ sets $PSNativeCommandUseErrorActionPreference = $true by
    # default, which turns a non-zero native exit code into a terminating
    # error under $ErrorActionPreference = "Stop". We do not want that:
    # a FAIL exit code is a normal, expected outcome that the caller
    # inspects explicitly.
    $oldNativeEAP = $null
    try { $oldNativeEAP = Get-Variable PSNativeCommandUseErrorActionPreference -ErrorAction SilentlyContinue } catch {}
    $previousErrorAction = $ErrorActionPreference
    $ErrorActionPreference = "Continue"

    try {
        if ($Silent) {
            & $ClientExe @args 2>&1 | Out-File -FilePath $logFile -Encoding utf8
        } else {
            & $ClientExe @args 2>&1 | Tee-Object -FilePath $logFile | Out-Host
        }
        $exitCode = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $previousErrorAction
    }

    # Parse the client's summary line.
    $summary = $null
    if (Test-Path $logFile) {
        $summaryLine = Get-Content $logFile -ErrorAction SilentlyContinue |
            Where-Object { $_ -match '"event"\s*:\s*"summary"' -and $_ -match '"role"\s*:\s*"client"' } |
            Select-Object -Last 1

        if ($summaryLine) {
            try { $summary = $summaryLine | ConvertFrom-Json } catch {}
        }
    }

    return @{
        LogFile  = $logFile
        ExitCode = $exitCode
        Summary  = $summary
    }
}

# ---- 8. Main flow ----------------------------------------------------------
$ScenarioResults = @()
$OverallExitCode = 0

try {
    # 8a. Start service.
    $serviceArgs = @("--ci", "--shutdown-after", "$ServiceShutdownAfter")
    if (-not $Quiet) {
        Write-Host ""
        Write-Host ("  Starting StressService (shutdown-after {0}s)..." -f $ServiceShutdownAfter) -ForegroundColor DarkGray
    }
    $ServiceProc = Start-Process -FilePath $Service `
        -ArgumentList $serviceArgs `
        -RedirectStandardOutput $ServiceLog `
        -RedirectStandardError  "$ServiceLog.err" `
        -PassThru -NoNewWindow

    # 8b. Start monitor.
    $monitorArgs = @("--ci", "--duration", "$MonitorDuration")
    if (-not $Quiet) {
        Write-Host ("  Starting StressMonitor (duration {0}s)..." -f $MonitorDuration) -ForegroundColor DarkGray
    }
    $MonitorProc = Start-Process -FilePath $Monitor `
        -ArgumentList $monitorArgs `
        -RedirectStandardOutput $MonitorLog `
        -RedirectStandardError  "$MonitorLog.err" `
        -PassThru -NoNewWindow

    # 8c. Wait for service ready.
    $serviceReady = $false
    for ($i = 0; $i -lt 50; $i++) {
        if (Test-Path $ServiceLog) {
            $content = Get-Content $ServiceLog -Raw -ErrorAction SilentlyContinue
            if ($content -and $content -match '"event"\s*:\s*"ready"') {
                $serviceReady = $true
                break
            }
        }
        Start-Sleep -Milliseconds 200
    }
    if (-not $serviceReady) {
        Write-Host ""
        Write-Host "  WARNING: Service did not emit ready event within 10 s." -ForegroundColor Yellow
        Write-Host "           Continuing anyway." -ForegroundColor Yellow
    }

    # 8d. Run each scenario in sequence.
    foreach ($s in $Scenarios) {
        $r = Invoke-Scenario -Scenario $s `
                             -ClientExe $Client `
                             -OutputDir $ScriptDir `
                             -Silent:$Quiet
        $ScenarioResults += @{
            Scenario = $s
            Run      = $r
        }

        if ($r.ExitCode -ne 0) {
            $OverallExitCode = 1
        }

        # Give the previous client's handles a moment to drain.
        Start-Sleep -Seconds 3
    }
}
finally {
    # Wait for service + monitor to finish naturally, then clean up.
    if ($null -ne $MonitorProc) {
        try { $MonitorProc.WaitForExit(15000) | Out-Null } catch {}
    }
    if ($null -ne $ServiceProc) {
        try { $ServiceProc.WaitForExit(15000) | Out-Null } catch {}
    }
    Stop-ChildProcesses
}

# ---- 9. Merge all streams into one combined report -------------------------
$combinedStreams = @($ServiceLog, $MonitorLog)
foreach ($sr in $ScenarioResults) {
    $combinedStreams += $sr.Run.LogFile
}
foreach ($f in $combinedStreams) {
    if (Test-Path $f) {
        Get-Content $f -ErrorAction SilentlyContinue | Add-Content $Report
    }
}

# ---- 10. Build the summary table -------------------------------------------
#  Every scenario produces one row. The columns are:
#
#      Scenario | Threads | Duration | Notify/s | Call/s | Success | Status
#
#  Plus a few derived quantities for the observation paragraph.

$rows = @()
foreach ($sr in $ScenarioResults) {
    $s = $sr.Scenario
    $sum = $sr.Run.Summary

    if ($null -ne $sum) {
        $rows += [PSCustomObject]@{
            Name         = $s.Name
            Title        = $s.Title
            Threads      = [int]$sum.threads
            Duration     = [int]$sum.duration_sec
            NotifyRate   = [uint64]$sum.notify_rate
            CallRate     = [uint64]$sum.call_rate
            CallTotal    = [uint64]$sum.call_total
            NotifyTotal  = [uint64]$sum.notify_total
            SuccessPct   = [double]$sum.success_pct
            Status       = [string]$sum.status
            LogFile      = $sr.Run.LogFile
        }
    } else {
        $rows += [PSCustomObject]@{
            Name         = $s.Name
            Title        = $s.Title
            Threads      = [int]$s.Threads
            Duration     = [int]$s.Duration
            NotifyRate   = 0
            CallRate     = 0
            CallTotal    = 0
            NotifyTotal  = 0
            SuccessPct   = 0.0
            Status       = "NO_DATA"
            LogFile      = $sr.Run.LogFile
        }
    }
}

# ---- 11. Print the summary table -------------------------------------------
$table = New-Object System.Text.StringBuilder
function Add-Line([string]$s) { [void]$table.AppendLine($s) }

Add-Line ""
Add-Line "======================================================================"
Add-Line "  LingoFuse Stress -- Comparison Summary"
Add-Line "======================================================================"
Add-Line ""
Add-Line ("  {0,-24} {1,8} {2,10} {3,14} {4,14} {5,10} {6,8}" -f `
          "Scenario", "Threads", "Duration", "Notify/s", "Call/s", "Success", "Status")
Add-Line ("  {0,-24} {1,8} {2,10} {3,14} {4,14} {5,10} {6,8}" -f `
          ("-" * 24), ("-" * 8), ("-" * 10), ("-" * 14), ("-" * 14), ("-" * 10), ("-" * 8))

foreach ($r in $rows) {
    $notifyStr = if ($r.NotifyRate -gt 0) { "{0:N0}" -f $r.NotifyRate } else { "-" }
    $callStr   = if ($r.CallRate   -gt 0) { "{0:N0}" -f $r.CallRate   } else { "-" }
    Add-Line ("  {0,-24} {1,8} {2,9}s {3,14} {4,14} {5,9:F2}% {6,8}" -f `
              $r.Title, $r.Threads, $r.Duration, $notifyStr, $callStr, $r.SuccessPct, $r.Status)
}

Add-Line ""

# ---- 12. Auto-generated observations ----------------------------------------
Add-Line "======================================================================"
Add-Line "  Observations"
Add-Line "======================================================================"
Add-Line ""

# Helper: find a row by name fragment.
function Find-Row([string]$fragment) {
    foreach ($r in $rows) {
        if ($r.Name -like "*$fragment*") { return $r }
    }
    return $null
}

# --- Notify throughput observation ---
$notifyRow = Find-Row "Notify"
if ($null -ne $notifyRow -and $notifyRow.NotifyRate -gt 0) {
    Add-Line ("  Notify throughput ({0} threads, {1} msg/loop):" -f `
              $notifyRow.Threads, 20)
    Add-Line ("      {0:N0} notify/s sustained" -f $notifyRow.NotifyRate)
    Add-Line ""
    Add-Line "      A single worker thread dispatches notify messages back-to-back"
    Add-Line "      without waiting. Notify throughput scales with the dispatch"
    Add-Line "      rate per thread, not with the number of threads. To increase"
    Add-Line "      it, raise --notify-per-loop."
    Add-Line ""
}

# --- Call scaling observation ---
$callRows = $rows | Where-Object { $_.Name -like "Call-*" } | Sort-Object Threads
if ($callRows.Count -ge 2) {
    $first = $callRows[0]
    $last  = $callRows[-1]
    $ratio = if ($first.CallRate -gt 0) {
        [double]$last.CallRate / [double]$first.CallRate
    } else { 0 }

    Add-Line "  Call throughput scaling (pure Call workload):"
    Add-Line ""
    Add-Line ("      {0,6} threads  ->  {1,8:N0} call/s   (baseline)" -f `
              $first.Threads, $first.CallRate)
    foreach ($r in $callRows[1..($callRows.Count - 1)]) {
        $rel = if ($first.CallRate -gt 0) {
            [double]$r.CallRate / [double]$first.CallRate
        } else { 0 }
        Add-Line ("      {0,6} threads  ->  {1,8:N0} call/s   ({2:F2}x)" -f `
                  $r.Threads, $r.CallRate, $rel)
    }
    Add-Line ""
    Add-Line ("      Observed scaling from {0} to {1} threads: {2:F2}x" -f `
              $first.Threads, $last.Threads, $ratio)
    Add-Line ""
    Add-Line "      Call is synchronous: every worker thread waits for a response"
    Add-Line "      before issuing the next one. Call throughput therefore scales"
    Add-Line "      with the number of worker threads, up to the server's"
    Add-Line "      saturation point. Beyond that point the marginal gain per"
    Add-Line "      thread drops sharply."
    Add-Line ""
}

# --- Mixed mode observation ---
$mixedRow = Find-Row "Mixed"
if ($null -ne $mixedRow -and $mixedRow.CallRate -gt 0) {
    Add-Line ("  Mixed 20:1 workload ({0} threads):" -f $mixedRow.Threads)
    Add-Line ("      {0:N0} notify/s  +  {1:N0} call/s" -f `
              $mixedRow.NotifyRate, $mixedRow.CallRate)
    Add-Line ""
    Add-Line "      When a worker shares its loop between notify and call, the"
    Add-Line "      synchronous call blocks the next notify dispatch. For maximum"
    Add-Line "      Notify throughput, use dedicated notify-only workers."
    Add-Line ""
}

# --- Comparison: Call vs Notify ---
if ($null -ne $notifyRow -and $callRows.Count -ge 1) {
    $maxCall = ($callRows | Measure-Object -Property CallRate -Maximum).Maximum
    if ($maxCall -gt 0) {
        $ratio = [double]$notifyRow.NotifyRate / [double]$maxCall
        Add-Line "  Throughput ratio (single process, single endpoint):"
        Add-Line ("      Notify/s  /  Call/s  =  {0:N0} / {1:N0}  =  {2:F1}x" -f `
                  $notifyRow.NotifyRate, $maxCall, $ratio)
        Add-Line ""
        Add-Line "      Notify and Call satisfy different requirements. Choose the"
        Add-Line "      mode that matches the workload: fire-and-forget for"
        Add-Line "      high-frequency state broadcasts, synchronous Call for"
        Add-Line "      request-response semantics."
        Add-Line ""
    }
}

Add-Line "======================================================================"
Add-Line "  Detailed reports"
Add-Line "======================================================================"
foreach ($r in $rows) {
    Add-Line ("    {0,-30} : {1}" -f $r.Title, $r.LogFile)
}
Add-Line ("    {0,-30} : {1}" -f "Service report", $ServiceLog)
Add-Line ("    {0,-30} : {1}" -f "Monitor report", $MonitorLog)
Add-Line ("    {0,-30} : {1}" -f "Combined report", $Report)
Add-Line ""

# --- Final verdict ---
if ($OverallExitCode -eq 0) {
    Add-Line "  RESULT: ALL SCENARIOS PASSED"
} else {
    Add-Line "  RESULT: ONE OR MORE SCENARIOS FAILED"
}
Add-Line "======================================================================"

# Write summary to both console and file.
$tableText = $table.ToString()
Write-Host $tableText
$tableText | Out-File -FilePath $SummaryFile -Encoding utf8

# Colour the final verdict on the console.
Write-Host ""
if ($OverallExitCode -eq 0) {
    Write-Host "  RESULT: ALL SCENARIOS PASSED" -ForegroundColor Green
} else {
    Write-Host "  RESULT: ONE OR MORE SCENARIOS FAILED" -ForegroundColor Red
}
Write-Host ""
Write-Host ("  Summary  : {0}" -f $SummaryFile)
Write-Host ""

exit $OverallExitCode