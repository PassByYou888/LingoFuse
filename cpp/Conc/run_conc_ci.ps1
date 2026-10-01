# =============================================================================
#  run_conc_ci.ps1
# -----------------------------------------------------------------------------
#  One-shot CI orchestration for the LingoFuse concurrent-notify demo on
#  Windows.
#
#  It starts ConcService and ConcClient, waits for the client to finish,
#  merges every JSON Lines event into a single report, and returns the
#  client's exit code to the caller.
#
#  Design goals:
#      - One command, one verdict, one exit code.
#      - Zero configuration when the default scenario is acceptable.
#      - Every artifact written to the script's own directory.
#
#  Usage:
#      .\run_conc_ci.ps1
#      .\run_conc_ci.ps1 -Batches 20 -Size 1000 -Threads 8
#      .\run_conc_ci.ps1 -Duration 30 -Size 10000 -Threads 8
#
#  Exit codes:
#      0  all batches PASS and CI thresholds satisfied
#      1  at least one batch failed, or a CI threshold was missed
#      2  startup error (missing exe, missing runtime library, ...)
# =============================================================================

param(
    [int] $Batches        = 20,
    [int] $Size           = 10000,
    [int] $Threads        = 8,
    [int] $Pause          = 50,
    [int] $Duration       = 0,
    [int] $MinBatches     = 0,
    [int] $MinTotalSent   = 0,
    [double] $MinAvgRate  = 0,
    [int] $ServiceLifetime = 0,   # 0 = auto (= estimated client time + 15 s)
    [switch] $Quiet
)

$ErrorActionPreference = "Stop"

# ---- 1. Locate the Binary directory ----------------------------------------
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
    if (Test-Path (Join-Path $resolved "ConcService.exe")) {
        $Bin = $resolved
        break
    }
}

if (-not $Bin) {
    Write-Host "Could not locate ConcService.exe. Searched:" -ForegroundColor Red
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

$Service = Join-Path $Bin "ConcService.exe"
$Client  = Join-Path $Bin "ConcClient.exe"

foreach ($f in @($Service, $Client)) {
    if (-not (Test-Path $f)) {
        Write-Host "Missing executable: $f" -ForegroundColor Red
        exit 2
    }
}

# ---- 2. Estimate the service lifetime ---------------------------------------
#  Client time budget = Batches * (send_ms + call_ms + pause).
#  In practice, send_ms ≈ 1200 ms and call_ms ≈ 1500 ms for 10000-message
#  batches, so we use a rough constant. When --Duration is set, it is the
#  authoritative limit.
if ($ServiceLifetime -le 0) {
    if ($Duration -gt 0) {
        $ServiceLifetime = $Duration + 15
    } else {
        # Very rough: ~3 s per 10000-message batch, floor at 30 s.
        $perBatch = 3
        $estimate = [int]($Batches * $perBatch) + 15
        if ($estimate -lt 30) { $estimate = 30 }
        $ServiceLifetime = $estimate
    }
}

# ---- 3. Output files --------------------------------------------------------
$Report     = Join-Path $ScriptDir "conc_ci_report.jsonl"
$ServiceLog = Join-Path $ScriptDir "conc_ci_service.jsonl"
$ClientLog  = Join-Path $ScriptDir "conc_ci_client.jsonl"

foreach ($f in @($Report, $ServiceLog, $ClientLog)) {
    if (Test-Path $f) { Remove-Item $f -Force }
}

# ---- 4. Banner --------------------------------------------------------------
Write-Host ""
Write-Host "======================================================================" -ForegroundColor Cyan
Write-Host "  LingoFuse Concurrent Notify -- CI run (Windows)" -ForegroundColor Cyan
Write-Host "======================================================================" -ForegroundColor Cyan
Write-Host ("  Binary directory  : {0}" -f $Bin)
if ($Duration -gt 0) {
    Write-Host ("  Client shape      : --duration {0}s  --size {1}  --threads {2}" -f $Duration, $Size, $Threads)
} else {
    Write-Host ("  Client shape      : --batches {0}  --size {1}  --threads {2}" -f $Batches, $Size, $Threads)
}
Write-Host ("  Service lifetime  : {0}s" -f $ServiceLifetime)
Write-Host ("  Report            : {0}" -f $Report)
Write-Host "======================================================================" -ForegroundColor Cyan
Write-Host ""

# ---- 5. Child process cleanup helper ---------------------------------------
$ServiceProc = $null

function Stop-ChildProcesses {
    if ($null -ne $script:ServiceProc) {
        try {
            if (-not $script:ServiceProc.HasExited) {
                $script:ServiceProc.Kill()
            }
        } catch {}
    }
    Get-Process ConcService, ConcClient -ErrorAction SilentlyContinue |
        Stop-Process -Force -ErrorAction SilentlyContinue
}

# ---- 6. Main flow ----------------------------------------------------------
$ClientExit = 1

try {
    # 6a. Start the service.
    $serviceArgs = @("--ci", "--shutdown-after", "$ServiceLifetime")
    if (-not $Quiet) {
        Write-Host ("  Starting ConcService (shutdown-after {0}s)..." -f $ServiceLifetime) -ForegroundColor DarkGray
    }
    $ServiceProc = Start-Process -FilePath $Service `
        -ArgumentList $serviceArgs `
        -RedirectStandardOutput $ServiceLog `
        -RedirectStandardError  "$ServiceLog.err" `
        -PassThru -NoNewWindow

    # 6b. Wait for service_ready.
    $serviceReady = $false
    for ($i = 0; $i -lt 50; $i++) {
        if (Test-Path $ServiceLog) {
            $content = Get-Content $ServiceLog -Raw -ErrorAction SilentlyContinue
            if ($content -and $content -match '"event"\s*:\s*"service_ready"') {
                $serviceReady = $true
                break
            }
        }
        Start-Sleep -Milliseconds 200
    }
    if (-not $serviceReady) {
        Write-Host ""
        Write-Host "  WARNING: ConcService did not emit service_ready within 10 s." -ForegroundColor Yellow
        Write-Host "           Continuing anyway; the client will retry discovery." -ForegroundColor Yellow
    }

    # 6b'. Give the framework a moment to propagate the service discovery
    #      broadcast before the client starts looking for it.
    Start-Sleep -Milliseconds 500

    # 6c. Run the client (blocking).
    $clientArgs = @("--ci", "--size", "$Size", "--threads", "$Threads",
                    "--pause", "$Pause")
    if ($Duration -gt 0) {
        $clientArgs += @("--duration", "$Duration")
    } else {
        $clientArgs += @("--batches", "$Batches")
    }
    if ($MinBatches   -gt 0) { $clientArgs += @("--min-batches",    "$MinBatches") }
    if ($MinTotalSent -gt 0) { $clientArgs += @("--min-total-sent", "$MinTotalSent") }
    if ($MinAvgRate   -gt 0) { $clientArgs += @("--min-avg-rate",   "$MinAvgRate") }

    # PS 7.3+ turns a non-zero native exit code into a terminating error
    # under $ErrorActionPreference = "Stop". We deliberately want a FAIL
    # exit code to be a normal, inspectable outcome, so relax it locally.
    $previousErrorAction = $ErrorActionPreference
    $ErrorActionPreference = "Continue"

    try {
        if ($Quiet) {
            & $Client @clientArgs 2>&1 |
                Out-File -FilePath $ClientLog -Encoding utf8
        } else {
            & $Client @clientArgs 2>&1 |
                Tee-Object -FilePath $ClientLog |
                Out-Host
        }
        $ClientExit = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $previousErrorAction
    }
}
finally {
    # Wait for the service to exit naturally, then clean up.
    if ($null -ne $ServiceProc) {
        try { $ServiceProc.WaitForExit(15000) | Out-Null } catch {}
    }
    Stop-ChildProcesses
}

# ---- 7. Merge every stream into a single report -----------------------------
foreach ($f in @($ServiceLog, $ClientLog)) {
    if (Test-Path $f) {
        Get-Content $f -ErrorAction SilentlyContinue | Add-Content $Report
    }
}

# ---- 8. Print a compact final summary --------------------------------------
Write-Host ""
Write-Host "======================================================================" -ForegroundColor Cyan
Write-Host "  CI run finished" -ForegroundColor Cyan
Write-Host "======================================================================" -ForegroundColor Cyan
Write-Host ("  Client exit code  : {0}" -f $ClientExit)
Write-Host ("  Full report       : {0}" -f $Report)
Write-Host ""

# Try to extract the client's summary line for a quick verdict.
if (Test-Path $Report) {
    $summaryLine = Get-Content $Report -ErrorAction SilentlyContinue |
        Where-Object {
            $_ -match '"event"\s*:\s*"summary"' -and
            $_ -match '"role"\s*:\s*"client"'
        } |
        Select-Object -Last 1

    if ($summaryLine) {
        try {
            $s = $summaryLine | ConvertFrom-Json
            Write-Host ("  Elapsed           : {0:N2} s" -f $s.elapsed_sec)
            Write-Host ("  Batches           : {0} passed / {1} total" -f $s.batches_passed, $s.batch_count)
            Write-Host ("  Total sent        : {0:N0}" -f $s.total_sent)
            Write-Host ("  Average rate      : {0:N0} notify/s" -f $s.avg_rate)
            Write-Host ("  Latency p95       : {0} us" -f $s.lat_p95_us)
            Write-Host ("  Status            : {0}" -f $s.status)
            if ($s.status -ne "PASS" -and $s.PSObject.Properties.Name -contains "reason") {
                Write-Host ("  Reason            : {0}" -f $s.reason)
            }
        } catch {
            Write-Host "  (could not parse client summary)"
        }
    }
}

Write-Host ""
if ($ClientExit -eq 0) {
    Write-Host "  RESULT: PASS" -ForegroundColor Green
} else {
    Write-Host "  RESULT: FAIL" -ForegroundColor Red
}
Write-Host "======================================================================" -ForegroundColor Cyan

exit $ClientExit