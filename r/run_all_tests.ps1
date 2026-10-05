<#
.SYNOPSIS
    Run every LingoFuse R binding test in sequence.

.DESCRIPTION
    Orchestrates the full test pipeline described in the LingoFuse R
    README:

      0. (optional) clean the tree
      1. (optional) build lfR_bridge.dll and the C++ test binaries
      2. (optional) install the R package (which also copies the
         bridge sources into lingofuse/src/ and regenerates
         roxygen2 output when NAMESPACE or man/ is missing)
      3. (optional) run R CMD check on the package
      4. STEP 1 - smoke_test.R          (bridge DLL, no runtime)
      5. STEP 2 - abi_test.R            (C ABI, no network)
      6. STEP 3a - test_service.exe  +  caller_test.R
      7. STEP 3b - callee_test.R     +  echo_client.exe
      8. STEP 4 - cross_node.R       +  cross_client.exe
      9. demo   - demo\server.R      +  demo\client.R

    Two-process tests are orchestrated automatically:

      - the long-running side (a service) is launched in the
        background via Start-Process and stopped in a finally block;
      - the short-running side (a client) is executed in the
        foreground with an empty line piped to its stdin so that its
        final "Press Enter to exit" prompt is satisfied immediately.
        All of the client's real work happens before that prompt.

    Every test writes its own log file under .\test_logs\.

.PARAMETER RuntimeDir
    Path to the LingoFuse runtime directory. When omitted the script
    consults the LINGOFUSE_RUNTIME environment variable and then a
    list of relative probes under the repository root.

.PARAMETER SkipClean
    Do not run .\clean.ps1 -All before building.

.PARAMETER SkipBuild
    Do not run .\build.ps1 -Rebuild or .\build_package.ps1 -Rebuild.

.PARAMETER SkipInstall
    Do not install the R package (implies SkipBuild's package half).

.PARAMETER SkipCheck
    Do not run .\check_package.ps1.

.EXAMPLE
    .\run_all_tests.ps1

.EXAMPLE
    .\run_all_tests.ps1 -RuntimeDir D:\CoreLibrary\LingoFuse\Binary

.EXAMPLE
    .\run_all_tests.ps1 -SkipClean -SkipBuild -SkipInstall -SkipCheck
#>

[CmdletBinding()]
param(
    [string]$RuntimeDir,
    [switch]$SkipClean,
    [switch]$SkipBuild,
    [switch]$SkipInstall,
    [switch]$SkipCheck
)

$ErrorActionPreference = "Continue"

$Root      = $PSScriptRoot
$CExtTests = Join-Path $Root "c_ext\tests"
$DemoDir   = Join-Path $Root "demo"
$LogDir    = Join-Path $Root "test_logs"

$Rexe    = (Get-Command R.exe      -ErrorAction SilentlyContinue).Source
$Rscript = (Get-Command Rscript.exe -ErrorAction SilentlyContinue).Source

# -----------------------------------------------------------------------------
# Output helpers
# -----------------------------------------------------------------------------

function Write-Banner { param([string]$Text)
    Write-Host ""
    Write-Host ("#" * 72) -ForegroundColor Cyan
    Write-Host ("# " + $Text) -ForegroundColor Cyan
    Write-Host ("#" * 72) -ForegroundColor Cyan
}
function Write-Section { param([string]$Text)
    Write-Host ""
    Write-Host ("=" * 72) -ForegroundColor Cyan
    Write-Host $Text -ForegroundColor Cyan
    Write-Host ("=" * 72) -ForegroundColor Cyan
}
function Write-Ok   { param([string]$Text) Write-Host ("[OK]   " + $Text) -ForegroundColor Green }
function Write-Fail { param([string]$Text) Write-Host ("[FAIL] " + $Text) -ForegroundColor Red }
function Write-Warn { param([string]$Text) Write-Host ("[WARN] " + $Text) -ForegroundColor Yellow }
function Write-Info { param([string]$Text) Write-Host ("       " + $Text) -ForegroundColor Gray }

# -----------------------------------------------------------------------------
# Test result tracking
# -----------------------------------------------------------------------------

$script:Results = @()

function Add-Result {
    param([string]$Name, [string]$Status, [string]$Detail = "")
    $script:Results += [pscustomobject]@{
        Name   = $Name
        Status = $Status
        Detail = $Detail
    }
}

# -----------------------------------------------------------------------------
# Runtime directory resolution
# -----------------------------------------------------------------------------

function Resolve-RuntimeDir {
    param([string]$Explicit)

    if ($Explicit -and (Test-Path -LiteralPath $Explicit -PathType Container)) {
        return (Resolve-Path -LiteralPath $Explicit).Path
    }
    if ($env:LINGOFUSE_RUNTIME -and
        (Test-Path -LiteralPath $env:LINGOFUSE_RUNTIME -PathType Container)) {
        return (Resolve-Path -LiteralPath $env:LINGOFUSE_RUNTIME).Path
    }

    $bases = @($Root, (Get-Location).Path)
    $relatives = @(
        "Binary", "runtime", "runtime\Binary", "lib",
        "..\Binary", "..\runtime", "..\runtime\Binary",
        "..\..\Binary", "..\..\runtime", "..\..\runtime\Binary",
        "..\..\..\Binary"
    )
    foreach ($base in $bases) {
        foreach ($rel in $relatives) {
            $candidate = Join-Path $base $rel
            if (Test-Path -LiteralPath $candidate -PathType Container) {
                return (Resolve-Path -LiteralPath $candidate).Path
            }
        }
    }
    return $null
}

# -----------------------------------------------------------------------------
# Pre-flight
# -----------------------------------------------------------------------------

Write-Banner "LingoFuse R - run every test"

if (-not $Rexe)    { Write-Fail "R.exe not found on PATH."; exit 1 }
if (-not $Rscript) { Write-Fail "Rscript.exe not found on PATH."; exit 1 }
Write-Ok ("R.exe     : " + $Rexe)
Write-Ok ("Rscript   : " + $Rscript)

$resolvedRuntime = Resolve-RuntimeDir -Explicit $RuntimeDir
if (-not $resolvedRuntime) {
    Write-Fail "Runtime directory not found."
    Write-Info "Pass -RuntimeDir <path>, or set LINGOFUSE_RUNTIME, or place"
    Write-Info "the runtime in a Binary\ subdirectory of the repository."
    exit 1
}
Write-Ok ("Runtime   : " + $resolvedRuntime)

if (-not (Test-Path -LiteralPath $LogDir -PathType Container)) {
    New-Item -ItemType Directory -Path $LogDir -Force | Out-Null
}
Write-Ok ("Log dir   : " + $LogDir)

# -----------------------------------------------------------------------------
# 0. Clean (optional)
# -----------------------------------------------------------------------------

if (-not $SkipClean) {
    Write-Section "0. clean.ps1 -All"
    Push-Location $Root
    try {
        & "$Root\clean.ps1" -All
        if ($LASTEXITCODE -eq 0) { Write-Ok "Clean complete."; Add-Result "clean" "PASS" }
        else { Write-Fail ("clean.ps1 exit code " + $LASTEXITCODE); Add-Result "clean" "FAIL" }
    } finally { Pop-Location }
} else {
    Write-Info "0. clean: skipped (-SkipClean)"
    Add-Result "clean" "SKIP"
}

# -----------------------------------------------------------------------------
# 1. Build the standalone bridge DLL and the C++ test binaries
# -----------------------------------------------------------------------------

if (-not $SkipBuild) {
    Write-Section "1a. build.ps1 -Rebuild"
    Push-Location $Root
    try {
        & "$Root\build.ps1" -Rebuild
        if ($LASTEXITCODE -eq 0) { Write-Ok "Bridge + C++ tests built."; Add-Result "build" "PASS" }
        else { Write-Fail ("build.ps1 exit code " + $LASTEXITCODE); Add-Result "build" "FAIL" }
    } finally { Pop-Location }

    Write-Section "1b. build_package.ps1 -Rebuild"
    Push-Location $Root
    try {
        & "$Root\build_package.ps1" -Rebuild
        if ($LASTEXITCODE -eq 0) { Write-Ok "Package built and installed."; Add-Result "build_package" "PASS" }
        else { Write-Fail ("build_package.ps1 exit code " + $LASTEXITCODE); Add-Result "build_package" "FAIL" }
    } finally { Pop-Location }
} else {
    Write-Info "1. build: skipped (-SkipBuild)"
    Add-Result "build" "SKIP"
    Add-Result "build_package" "SKIP"
}

# -----------------------------------------------------------------------------
# 2. Ensure roxygen2 output exists (build_package.ps1 may have covered this)
# -----------------------------------------------------------------------------

$pkgDir   = Join-Path $Root "lingofuse"
$nsPath   = Join-Path $pkgDir "NAMESPACE"
$manDir   = Join-Path $pkgDir "man"

$manEmpty = $true
if (Test-Path -LiteralPath $manDir) {
    $rdFiles = @(Get-ChildItem -Path $manDir -Filter "*.Rd" -File -ErrorAction SilentlyContinue)
    if ($rdFiles.Count -gt 0) { $manEmpty = $false }
}

if (-not (Test-Path -LiteralPath $nsPath) -or $manEmpty) {
    Write-Section "2. Regenerating roxygen2 output"
    if (-not (Test-Path -LiteralPath $nsPath)) { Write-Info "NAMESPACE is missing." }
    if ($manEmpty) { Write-Info "man\ contains no .Rd files." }

    # A minimal NAMESPACE stub is required before roxygen2 (via
    # pkgload) can load the package. The roxygenise() call will
    # overwrite it.
    if (-not (Test-Path -LiteralPath $nsPath)) {
        Write-Info "Writing a minimal NAMESPACE stub for roxygen2..."
        @'
# Generated by roxygen2: do not edit by hand

useDynLib(lingofuse, .registration = TRUE, .fixes = "C_")
'@ | Set-Content -Path $nsPath -Encoding ASCII
    }

    Push-Location $Root
    try {
        & $Rscript "-e" "roxygen2::roxygenise('lingofuse')"
        $roxRc = $LASTEXITCODE
    } finally { Pop-Location }

    if ($roxRc -eq 0) {
        Write-Ok "roxygen2 output regenerated."
        Add-Result "roxygen2" "PASS"
    } else {
        Write-Warn "roxygenise failed."
        Write-Warn "Install roxygen2 with:"
        Write-Warn "    Rscript -e `"install.packages('roxygen2')`""
        Add-Result "roxygen2" "WARN"
    }
} else {
    $rdCount = @(Get-ChildItem -Path $manDir -Filter "*.Rd" -File).Count
    Write-Info ("2. Roxygen2 output present (NAMESPACE + " + $rdCount + " .Rd file(s)).")
    Add-Result "roxygen2" "SKIP"
}

# -----------------------------------------------------------------------------
# 3. Reinstall R package (optional; build_package.ps1 already installed once)
# -----------------------------------------------------------------------------

if (-not $SkipInstall) {
    Write-Section "3. install_package.ps1 -NoRoxygen"
    Push-Location $Root
    try {
        & "$Root\install_package.ps1" -NoRoxygen
        if ($LASTEXITCODE -eq 0) { Write-Ok "Package installed."; Add-Result "install_package" "PASS" }
        else { Write-Fail ("install_package.ps1 exit code " + $LASTEXITCODE); Add-Result "install_package" "FAIL" }
    } finally { Pop-Location }
} else {
    Write-Info "3. install: skipped (-SkipInstall)"
    Add-Result "install_package" "SKIP"
}

# -----------------------------------------------------------------------------
# 4. R CMD check (optional)
# -----------------------------------------------------------------------------

if (-not $SkipCheck) {
    Write-Section "4. check_package.ps1 -NoRoxygen"
    Push-Location $Root
    try {
        & "$Root\check_package.ps1" -NoRoxygen
        if ($LASTEXITCODE -eq 0) { Write-Ok "R CMD check completed."; Add-Result "R CMD check" "PASS" }
        else { Write-Fail ("check_package.ps1 exit code " + $LASTEXITCODE); Add-Result "R CMD check" "FAIL" }
    } finally { Pop-Location }
} else {
    Write-Info "4. R CMD check: skipped (-SkipCheck)"
    Add-Result "R CMD check" "SKIP"
}

# -----------------------------------------------------------------------------
# 5. STEP 1 - smoke_test.R
# -----------------------------------------------------------------------------

Write-Section "5. STEP 1 - smoke_test.R (no runtime required)"
$rc = 0
Push-Location $Root
try {
    & $Rscript (Join-Path $CExtTests "smoke_test.R") 2>&1 |
        Tee-Object -FilePath (Join-Path $LogDir "step1_smoke_test.log")
    $rc = $LASTEXITCODE
} finally { Pop-Location }
if ($rc -eq 0) { Write-Ok "STEP 1 passed."; Add-Result "STEP 1 smoke_test.R" "PASS" }
else { Write-Fail ("STEP 1 exit code " + $rc); Add-Result "STEP 1 smoke_test.R" "FAIL" ("exit " + $rc) }

# -----------------------------------------------------------------------------
# 6. STEP 2 - abi_test.R
# -----------------------------------------------------------------------------

Write-Section "6. STEP 2 - abi_test.R (C ABI, no network)"
$rc = 0
Push-Location $Root
try {
    & $Rscript (Join-Path $CExtTests "abi_test.R") $resolvedRuntime 2>&1 |
        Tee-Object -FilePath (Join-Path $LogDir "step2_abi_test.log")
    $rc = $LASTEXITCODE
} finally { Pop-Location }
if ($rc -eq 0) { Write-Ok "STEP 2 passed."; Add-Result "STEP 2 abi_test.R" "PASS" }
else { Write-Fail ("STEP 2 exit code " + $rc); Add-Result "STEP 2 abi_test.R" "FAIL" ("exit " + $rc) }

# -----------------------------------------------------------------------------
# 7. STEP 3a - test_service.exe + caller_test.R
# -----------------------------------------------------------------------------

Write-Section "7. STEP 3a - test_service.exe + caller_test.R"

$testServiceExe = Join-Path $CExtTests "test_service.exe"
$svcLog         = Join-Path $LogDir    "step3a_test_service.log"
$cliLog         = Join-Path $LogDir    "step3a_caller_test.log"

if (-not (Test-Path -LiteralPath $testServiceExe)) {
    Write-Fail ("test_service.exe not found: " + $testServiceExe)
    Add-Result "STEP 3a caller_test.R" "SKIP" "test_service.exe missing"
} else {
    $svcProc = $null
    try {
        Write-Info "Launching test_service.exe in the background..."
        $svcProc = Start-Process -FilePath $testServiceExe `
            -ArgumentList @($resolvedRuntime) `
            -RedirectStandardOutput $svcLog `
            -RedirectStandardError  ($svcLog + ".err") `
            -PassThru -WindowStyle Hidden

        Write-Info "Waiting 3 seconds for the service to become visible..."
        Start-Sleep -Seconds 3

        Write-Info "Running caller_test.R..."
        Push-Location $Root
        try {
            & $Rscript (Join-Path $CExtTests "caller_test.R") $resolvedRuntime 2>&1 |
                Tee-Object -FilePath $cliLog
            $rc = $LASTEXITCODE
        } finally { Pop-Location }

        if ($rc -eq 0) { Write-Ok "STEP 3a passed."; Add-Result "STEP 3a caller_test.R" "PASS" }
        else { Write-Fail ("STEP 3a exit code " + $rc); Add-Result "STEP 3a caller_test.R" "FAIL" ("exit " + $rc) }
    } finally {
        if ($svcProc -and -not $svcProc.HasExited) {
            Write-Info "Stopping test_service.exe..."
            try { Stop-Process -Id $svcProc.Id -Force -ErrorAction SilentlyContinue } catch { }
            try { Wait-Process  -Id $svcProc.Id -Timeout 3 -ErrorAction SilentlyContinue } catch { }
        }
    }
}

# -----------------------------------------------------------------------------
# 8. STEP 3b - callee_test.R + echo_client.exe
# -----------------------------------------------------------------------------

Write-Section "8. STEP 3b - callee_test.R + echo_client.exe"

$echoExe   = Join-Path $CExtTests "echo_client.exe"
$calleeLog = Join-Path $LogDir    "step3b_callee_test.log"
$echoLog   = Join-Path $LogDir    "step3b_echo_client.log"

if (-not (Test-Path -LiteralPath $echoExe)) {
    Write-Fail ("echo_client.exe not found: " + $echoExe)
    Add-Result "STEP 3b callee_test.R" "SKIP" "echo_client.exe missing"
} else {
    $calleeProc = $null
    try {
        Write-Info "Launching callee_test.R in the background (20 s window)..."
        $calleeProc = Start-Process -FilePath $Rscript `
            -ArgumentList @((Join-Path $CExtTests "callee_test.R"), $resolvedRuntime, "20") `
            -RedirectStandardOutput $calleeLog `
            -RedirectStandardError  ($calleeLog + ".err") `
            -PassThru -WindowStyle Hidden

        Write-Info "Waiting 3 seconds for the R service to become visible..."
        Start-Sleep -Seconds 3

        Write-Info "Running echo_client.exe (empty line piped to stdin)."
        "" | & $echoExe $resolvedRuntime 2>&1 |
            Tee-Object -FilePath $echoLog
        $rc = $LASTEXITCODE

        Write-Info "Waiting for callee_test.R to shut down..."
        if ($calleeProc) {
            try { Wait-Process -Id $calleeProc.Id -Timeout 25 -ErrorAction SilentlyContinue } catch { }
        }

        if ($rc -eq 0) { Write-Ok "STEP 3b passed."; Add-Result "STEP 3b callee_test.R" "PASS" }
        else { Write-Fail ("STEP 3b exit code " + $rc); Add-Result "STEP 3b callee_test.R" "FAIL" ("exit " + $rc) }
    } finally {
        if ($calleeProc -and -not $calleeProc.HasExited) {
            Write-Info "Stopping callee_test.R..."
            try { Stop-Process -Id $calleeProc.Id -Force -ErrorAction SilentlyContinue } catch { }
        }
    }
}

# -----------------------------------------------------------------------------
# 9. STEP 4 - cross_node.R + cross_client.exe
# -----------------------------------------------------------------------------

Write-Section "9. STEP 4 - cross_node.R + cross_client.exe"

$crossExe = Join-Path $CExtTests "cross_client.exe"
$nodeLog  = Join-Path $LogDir    "step4_cross_node.log"
$ccLog    = Join-Path $LogDir    "step4_cross_client.log"

if (-not (Test-Path -LiteralPath $crossExe)) {
    Write-Fail ("cross_client.exe not found: " + $crossExe)
    Add-Result "STEP 4 cross_node.R" "SKIP" "cross_client.exe missing"
} else {
    $nodeProc = $null
    try {
        Write-Info "Launching cross_node.R in the background (20 s window)..."
        $nodeProc = Start-Process -FilePath $Rscript `
            -ArgumentList @((Join-Path $CExtTests "cross_node.R"), $resolvedRuntime, "20") `
            -RedirectStandardOutput $nodeLog `
            -RedirectStandardError  ($nodeLog + ".err") `
            -PassThru -WindowStyle Hidden

        Write-Info "Waiting 3 seconds for the CrossDemo node to become visible..."
        Start-Sleep -Seconds 3

        Write-Info "Running cross_client.exe (empty line piped to stdin)."
        "" | & $crossExe $resolvedRuntime 2>&1 |
            Tee-Object -FilePath $ccLog
        $rc = $LASTEXITCODE

        Write-Info "Waiting for cross_node.R to shut down..."
        if ($nodeProc) {
            try { Wait-Process -Id $nodeProc.Id -Timeout 25 -ErrorAction SilentlyContinue } catch { }
        }

        if ($rc -eq 0) { Write-Ok "STEP 4 passed."; Add-Result "STEP 4 cross_node.R" "PASS" }
        else { Write-Fail ("STEP 4 exit code " + $rc); Add-Result "STEP 4 cross_node.R" "FAIL" ("exit " + $rc) }
    } finally {
        if ($nodeProc -and -not $nodeProc.HasExited) {
            Write-Info "Stopping cross_node.R..."
            try { Stop-Process -Id $nodeProc.Id -Force -ErrorAction SilentlyContinue } catch { }
        }
    }
}

# -----------------------------------------------------------------------------
# 10. demo - server.R + client.R
# -----------------------------------------------------------------------------

Write-Section "10. demo - server.R + client.R"

$srvLog  = Join-Path $LogDir "demo_server.log"
$cliLog  = Join-Path $LogDir "demo_client.log"
$serverR = Join-Path $DemoDir "server.R"
$clientR = Join-Path $DemoDir "client.R"

if (-not (Test-Path -LiteralPath $serverR)) {
    Write-Fail ("server.R not found: " + $serverR)
    Add-Result "demo server/client" "SKIP" "server.R missing"
} elseif (-not (Test-Path -LiteralPath $clientR)) {
    Write-Fail ("client.R not found: " + $clientR)
    Add-Result "demo server/client" "SKIP" "client.R missing"
} else {
    $srvProc = $null
    try {
        Write-Info "Launching demo\server.R in the background (20 s window)..."
        $srvProc = Start-Process -FilePath $Rscript `
            -ArgumentList @($serverR, $resolvedRuntime, "20") `
            -RedirectStandardOutput $srvLog `
            -RedirectStandardError  ($srvLog + ".err") `
            -PassThru -WindowStyle Hidden

        Write-Info "Waiting 3 seconds for the server to become visible..."
        Start-Sleep -Seconds 3

        Write-Info "Running demo\client.R..."
        Push-Location $Root
        try {
            & $Rscript $clientR $resolvedRuntime 2>&1 |
                Tee-Object -FilePath $cliLog
            $rc = $LASTEXITCODE
        } finally { Pop-Location }

        Write-Info "Waiting for demo\server.R to shut down..."
        if ($srvProc) {
            try { Wait-Process -Id $srvProc.Id -Timeout 25 -ErrorAction SilentlyContinue } catch { }
        }

        if ($rc -eq 0) { Write-Ok "demo passed."; Add-Result "demo server/client" "PASS" }
        else { Write-Fail ("demo exit code " + $rc); Add-Result "demo server/client" "FAIL" ("exit " + $rc) }
    } finally {
        if ($srvProc -and -not $srvProc.HasExited) {
            Write-Info "Stopping demo\server.R..."
            try { Stop-Process -Id $srvProc.Id -Force -ErrorAction SilentlyContinue } catch { }
        }
    }
}

# -----------------------------------------------------------------------------
# 11. Summary
# -----------------------------------------------------------------------------

Write-Banner "Test Summary"

$fmt = "{0,-32} {1,-6} {2}"
Write-Host ($fmt -f "Test", "Status", "Detail") -ForegroundColor White
Write-Host ("-" * 72)

foreach ($r in $script:Results) {
    $color = switch ($r.Status) {
        "PASS" { "Green" }
        "FAIL" { "Red" }
        "SKIP" { "Yellow" }
        "WARN" { "Yellow" }
        default { "Gray" }
    }
    Write-Host ($fmt -f $r.Name, $r.Status, $r.Detail) -ForegroundColor $color
}

$passCnt = @($script:Results | Where-Object { $_.Status -eq "PASS" }).Count
$failCnt = @($script:Results | Where-Object { $_.Status -eq "FAIL" }).Count
$skipCnt = @($script:Results | Where-Object { $_.Status -eq "SKIP" }).Count
$warnCnt = @($script:Results | Where-Object { $_.Status -eq "WARN" }).Count

Write-Host ("-" * 72)
Write-Host ""
Write-Host ("  Total   : " + $script:Results.Count)
Write-Host ("  Passed  : " + $passCnt) -ForegroundColor Green
Write-Host ("  Failed  : " + $failCnt) -ForegroundColor Red
Write-Host ("  Skipped : " + $skipCnt) -ForegroundColor Yellow
if ($warnCnt -gt 0) {
    Write-Host ("  Warned  : " + $warnCnt) -ForegroundColor Yellow
}
Write-Host ""
Write-Host ("  Logs are under: " + $LogDir) -ForegroundColor White
Write-Host ""

if ($failCnt -gt 0) { exit 1 }
exit 0