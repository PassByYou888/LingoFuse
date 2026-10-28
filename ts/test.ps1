[CmdletBinding()]
param(
    [ValidateSet("all", "v1", "v2", "cross")]
    [string]$Suite = "all",

    [ValidateSet("auto", "node", "bun", "deno")]
    [string]$Runtime = "auto",

    [switch]$SkipUnit,
    [switch]$SkipCross
)

$ErrorActionPreference = "Stop"

$script:root          = $PSScriptRoot
$script:isWin         = ($env:OS -eq "Windows_NT")
$script:totalPasses   = 0
$script:totalFailures = 0
$script:runtime       = $Runtime

function Write-Section {
    param([string]$m)
    Write-Host ""
    Write-Host ("=" * 72) -ForegroundColor DarkGray
    Write-Host $m -ForegroundColor White
    Write-Host ("=" * 72) -ForegroundColor DarkGray
}
function Write-Info { param([string]$m) Write-Host "[INFO] $m" -ForegroundColor Cyan }
function Write-Ok   { param([string]$m) Write-Host "[ OK ] $m" -ForegroundColor Green }
function Write-Warn { param([string]$m) Write-Host "[WARN] $m" -ForegroundColor Yellow }
function Write-Err  { param([string]$m) Write-Host "[FAIL] $m" -ForegroundColor Red }
function Write-Diag { param([string]$m) Write-Host "       $m" -ForegroundColor DarkGray }

if (-not $script:isWin) {
    Write-Err "This script targets Windows."
    exit 2
}

function Get-RuntimeExe {
    param([string]$Name)
    $cmd = Get-Command $Name -ErrorAction SilentlyContinue
    if ($null -eq $cmd) { return $null }
    return $cmd.Source
}

function Resolve-Runtime {
    if ($script:runtime -ne "auto") { return $script:runtime }
    if ($null -ne (Get-RuntimeExe "bun"))  { return "bun" }
    if ($null -ne (Get-RuntimeExe "deno")) { return "deno" }
    return "node"
}

function Get-TsxCliPath {
    $cli = Join-Path $script:root "node_modules\tsx\dist\cli.mjs"
    if (Test-Path -LiteralPath $cli) { return $cli }
    return $null
}

function Get-RuntimeCommand {
    param([string]$ScriptPath)

    if ($script:runtime -eq "node") {
        $node = Get-RuntimeExe "node"
        if ($null -eq $node) { throw "node is not on PATH." }
        $tsxCli = Get-TsxCliPath
        if ($null -eq $tsxCli) {
            throw "tsx cli.mjs not found under node_modules\tsx\dist\."
        }
        return @{
            Exe     = $node
            ArgList = @($tsxCli, $ScriptPath)
        }
    }
    if ($script:runtime -eq "bun") {
        $bun = Get-RuntimeExe "bun"
        if ($null -eq $bun) { throw "bun is not on PATH." }
        return @{
            Exe     = $bun
            ArgList = @("run", $ScriptPath)
        }
    }
    if ($script:runtime -eq "deno") {
        $deno = Get-RuntimeExe "deno"
        if ($null -eq $deno) { throw "deno is not on PATH." }
        return @{
            Exe     = $deno
            ArgList = @(
                "run",
                "--allow-ffi",
                "--allow-read",
                "--allow-env",
                "--allow-net",
                "--allow-sys",
                "--allow-run",
                $ScriptPath
            )
        }
    }
    throw "unknown runtime: $($script:runtime)"
}

function Build-ArgumentsString {
    param([string[]]$ArgList)
    $sb = New-Object System.Text.StringBuilder
    foreach ($a in $ArgList) {
        if ($sb.Length -gt 0) { [void]$sb.Append(' ') }
        [void]$sb.Append('"')
        [void]$sb.Append(($a -replace '"', '\"'))
        [void]$sb.Append('"')
    }
    return $sb.ToString()
}

function Invoke-Preflight {
    Write-Section "Preflight"

    $node = Get-RuntimeExe "node"
    if ($null -eq $node) {
        Write-Err "node is not on PATH."
        exit 2
    }
    Write-Info "Node.js : $(& node -v 2>$null)"

    $nm = Join-Path $script:root "node_modules"
    if (-not (Test-Path -LiteralPath $nm)) {
        Write-Err "node_modules is missing. Run: npm install"
        exit 2
    }
    Write-Info "node_modules present."

    if ($script:runtime -eq "node") {
        $tsxCli = Get-TsxCliPath
        if ($null -eq $tsxCli) {
            Write-Err "tsx cli.mjs not found. Run: npm install"
            exit 2
        }
        Write-Info "tsx cli : $tsxCli"
    }

    $distIndex = Join-Path $script:root "dist\index.js"
    if (-not (Test-Path -LiteralPath $distIndex)) {
        Write-Warn "dist/ is missing; run build.ps1 first."
    }
    else {
        Write-Info "dist/index.js present."
    }

    if ($script:runtime -eq "bun") {
        $b = Get-RuntimeExe "bun"
        if ($null -eq $b) { Write-Err "bun requested but not found."; exit 2 }
        Write-Info "bun : $(& bun --version 2>$null)"
    }
    elseif ($script:runtime -eq "deno") {
        $d = Get-RuntimeExe "deno"
        if ($null -eq $d) { Write-Err "deno requested but not found."; exit 2 }
        $dv = (& deno --version 2>$null | Select-Object -First 1)
        Write-Info "deno : $dv"
    }

    Write-Info "Selected runtime: $script:runtime"
}

function Invoke-UnitTest {
    param(
        [string]$Label,
        [string]$ScriptRelPath
    )

    $scriptPath = Join-Path $script:root $ScriptRelPath
    if (-not (Test-Path -LiteralPath $scriptPath)) {
        Write-Err "$Label skipped: $ScriptRelPath not found."
        $script:totalFailures += 1
        return $false
    }

    Write-Info "Running $Label ..."

    $proc = $null
    $stdout = ""
    $stderr = ""
    $rc = -1
    $timedOut = $false

    try {
        $cmd = Get-RuntimeCommand -ScriptPath $scriptPath

        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = $cmd.Exe
        $psi.UseShellExecute = $false
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $psi.CreateNoWindow = $true
        $psi.WorkingDirectory = $script:root
        $psi.StandardOutputEncoding = [System.Text.Encoding]::UTF8
        $psi.StandardErrorEncoding = [System.Text.Encoding]::UTF8
        $psi.Arguments = Build-ArgumentsString -ArgList $cmd.ArgList

        $proc = [System.Diagnostics.Process]::Start($psi)
        $stdoutTask = $proc.StandardOutput.ReadToEndAsync()
        $stderrTask = $proc.StandardError.ReadToEndAsync()

        if (-not $proc.WaitForExit(300000)) {
            $timedOut = $true
            try { $proc.Kill($true) } catch { try { $proc.Kill() } catch { } }
            try { $proc.WaitForExit(5000) | Out-Null } catch { }
        }
        $rc = $proc.ExitCode

        try { $stdout = $stdoutTask.GetAwaiter().GetResult() } catch { $stdout = "" }
        try { $stderr = $stderrTask.GetAwaiter().GetResult() } catch { $stderr = "" }
    }
    catch {
        Write-Err "$Label raised: $($_.Exception.Message)"
        $script:totalFailures += 1
        return $false
    }
    finally {
        if ($null -ne $proc) {
            try { $proc.Dispose() } catch { }
        }
    }

    $combined = "$stdout`n$stderr"
    foreach ($ln in ($combined -split "`r?`n")) {
        if ($ln.Length -gt 0) { Write-Diag $ln }
    }

    if ($timedOut) {
        Write-Err "$Label timed out after 300s."
        $script:totalFailures += 1
        return $false
    }

    if ($rc -eq 0) {
        Write-Ok "$Label passed."
        $script:totalPasses += 1
        return $true
    }

    Write-Err "$Label failed (exit $rc)."
    $script:totalFailures += 1
    return $false
}

function Start-CrossProcess {
    param(
        [string]$Name,
        [string]$ScriptRelPath
    )

    $scriptPath = Join-Path $script:root $ScriptRelPath
    if (-not (Test-Path -LiteralPath $scriptPath)) {
        throw "script not found: $scriptPath"
    }

    $cmd = Get-RuntimeCommand -ScriptPath $scriptPath

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $cmd.Exe
    $psi.UseShellExecute = $false
    $psi.RedirectStandardInput = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true
    $psi.WorkingDirectory = $script:root
    $psi.StandardOutputEncoding = [System.Text.Encoding]::UTF8
    $psi.StandardErrorEncoding = [System.Text.Encoding]::UTF8
    $psi.Arguments = Build-ArgumentsString -ArgList $cmd.ArgList

    $proc = [System.Diagnostics.Process]::Start($psi)

    $stdoutTask = $proc.StandardOutput.ReadToEndAsync()
    $stderrTask = $proc.StandardError.ReadToEndAsync()

    Write-Info "  [$Name] started PID=$($proc.Id)"

    return @{
        Name       = $Name
        Process    = $proc
        StdoutTask = $stdoutTask
        StderrTask = $stderrTask
    }
}

function Request-CrossProcessExit {
    param(
        $Handle,
        [int]$GraceMs = 15000
    )
    if ($null -eq $Handle) { return $true }
    $p = $Handle.Process
    if ($null -eq $p) { return $true }
    if ($p.HasExited) { return $true }

    try {
        $p.StandardInput.WriteLine("")
        $p.StandardInput.Flush()
    }
    catch { }

    $exited = $false
    try {
        $exited = $p.WaitForExit($GraceMs)
    }
    catch { $exited = $false }
    return $exited
}

function Stop-CrossProcess {
    param($Handle)
    if ($null -eq $Handle) { return }
    $p = $Handle.Process
    if ($null -eq $p) { return }

    if (-not $p.HasExited) {
        try {
            $p.StandardInput.WriteLine("")
            $p.StandardInput.Flush()
        }
        catch { }
        try { $p.WaitForExit(3000) | Out-Null } catch { }
    }

    if (-not $p.HasExited) {
        try {
            $null = & taskkill /T /F /PID $p.Id 2>&1
        }
        catch {
            try { $p.Kill() } catch { }
        }
        try { $p.WaitForExit(5000) | Out-Null } catch { }
        if (-not $p.HasExited) {
            try { $p.Kill() } catch { }
        }
    }

    try { $p.Dispose() } catch { }
}

function Read-CrossProcessOutput {
    param($Handle)
    if ($null -eq $Handle) {
        return @{ Stdout = ""; Stderr = "" }
    }
    $out = ""
    $err = ""
    try {
        if ($null -ne $Handle.StdoutTask) {
            $out = $Handle.StdoutTask.GetAwaiter().GetResult()
        }
    }
    catch { }
    try {
        if ($null -ne $Handle.StderrTask) {
            $err = $Handle.StderrTask.GetAwaiter().GetResult()
        }
    }
    catch { }
    return @{ Stdout = $out; Stderr = $err }
}

function Write-ProcessOutput {
    param(
        [string]$Name,
        [string]$Text
    )
    if ([string]::IsNullOrEmpty($Text)) {
        Write-Diag "[$Name] (no output)"
        return
    }
    foreach ($ln in ($Text -split "`r?`n")) {
        if ($ln.Length -gt 0) { Write-Diag "[$Name] $ln" }
    }
}

function Invoke-CrossTest {
    Write-Section "Cross test: service + node + call"

    $svc = $null
    $nod = $null
    $cal = $null
    $passed = $false

    try {
        Write-Info "Starting service ..."
        $svc = Start-CrossProcess -Name "service" -ScriptRelPath "cross/cross-service.ts"
        Write-Info "  waiting 10s for service to become ready ..."
        Start-Sleep -Seconds 10

        if ($svc.Process.HasExited) {
            $o = Read-CrossProcessOutput $svc
            Write-ProcessOutput -Name "service" -Text $o.Stdout
            Write-ProcessOutput -Name "service-err" -Text $o.Stderr
            throw "service exited prematurely (exit code $($svc.Process.ExitCode))"
        }
        Write-Ok "  service process is alive."

        Write-Info "Starting node ..."
        $nod = Start-CrossProcess -Name "node" -ScriptRelPath "cross/cross-node.ts"
        Write-Info "  waiting 8s for node to connect ..."
        Start-Sleep -Seconds 8

        if ($nod.Process.HasExited) {
            $o = Read-CrossProcessOutput $nod
            Write-ProcessOutput -Name "node" -Text $o.Stdout
            Write-ProcessOutput -Name "node-err" -Text $o.Stderr
            throw "node exited prematurely (exit code $($nod.Process.ExitCode))"
        }
        Write-Ok "  node process is alive."

        Write-Info "Starting call (load test runs for 10s) ..."
        $cal = Start-CrossProcess -Name "call" -ScriptRelPath "cross/cross-call.ts"
        Write-Info "  waiting 18s for load test to finish ..."
        Start-Sleep -Seconds 18

        Write-Info "Signaling call to exit (stdin newline) ..."
        $calExited = Request-CrossProcessExit -Handle $cal -GraceMs 15000
        if ($calExited) {
            Write-Ok "  call exited gracefully."
        }
        else {
            Write-Warn "  call did not exit within 15s after stdin close; killing."
            Stop-CrossProcess $cal
        }

        $calOut = Read-CrossProcessOutput $cal
        Write-ProcessOutput -Name "call" -Text $calOut.Stdout
        Write-ProcessOutput -Name "call-err" -Text $calOut.Stderr

        $combined = "$($calOut.Stdout)`n$($calOut.Stderr)"
        $totalMatch = [regex]::Match($combined, 'total calls\s*:\s*(\d+)')
        $failedMatch = [regex]::Match($combined, 'failed\s*:\s*(\d+)')
        $successMatch = [regex]::Match($combined, 'success\s*:\s*(\d+)')

        if (-not $totalMatch.Success -or -not $failedMatch.Success) {
            throw "could not parse call statistics from output"
        }

        $total = [int]$totalMatch.Groups[1].Value
        $failed = [int]$failedMatch.Groups[1].Value
        $success = if ($successMatch.Success) { [int]$successMatch.Groups[1].Value } else { 0 }

        Write-Info "  total=$total  success=$success  failed=$failed"

        if ($total -eq 0) {
            throw "call reported total=0 calls (service unreachable)"
        }
        if ($failed -gt 0) {
            throw "call reported $failed failed calls out of $total"
        }

        Write-Ok "Cross test passed."
        $passed = $true
        $script:totalPasses += 1
    }
    catch {
        Write-Err "Cross test failed: $($_.Exception.Message)"

        if ($null -ne $cal) {
            $o = Read-CrossProcessOutput $cal
            Write-ProcessOutput -Name "call" -Text $o.Stdout
            Write-ProcessOutput -Name "call-err" -Text $o.Stderr
        }
        if ($null -ne $nod) {
            $o = Read-CrossProcessOutput $nod
            Write-ProcessOutput -Name "node" -Text $o.Stdout
            Write-ProcessOutput -Name "node-err" -Text $o.Stderr
        }
        if ($null -ne $svc) {
            $o = Read-CrossProcessOutput $svc
            Write-ProcessOutput -Name "service" -Text $o.Stdout
            Write-ProcessOutput -Name "service-err" -Text $o.Stderr
        }

        $script:totalFailures += 1
    }
    finally {
        if ($null -ne $cal) { Stop-CrossProcess $cal }
        if ($null -ne $nod) { Stop-CrossProcess $nod }
        if ($null -ne $svc) { Stop-CrossProcess $svc }
    }

    return $passed
}

Write-Section "LingoFuse TypeScript test runner"

$script:runtime = Resolve-Runtime
Invoke-Preflight

$runUnit = $true
$runCross = $true

if ($SkipUnit) { $runUnit = $false }
if ($SkipCross) { $runCross = $false }

if ($Suite -eq "v1") { $runUnit = (-not $SkipUnit); $runCross = $false }
if ($Suite -eq "v2") { $runUnit = (-not $SkipUnit); $runCross = $false }
if ($Suite -eq "cross") { $runUnit = $false; $runCross = (-not $SkipCross) }
if ($Suite -eq "all") { $runUnit = (-not $SkipUnit); $runCross = (-not $SkipCross) }

if ($runUnit) {
    Write-Section "Unit tests"

    if ($Suite -eq "all" -or $Suite -eq "v1") {
        try {
            Invoke-UnitTest -Label "v1 baseline (test/test.ts)" -ScriptRelPath "test/test.ts" | Out-Null
        }
        catch {
            Write-Err "v1 baseline raised: $($_.Exception.Message)"
            $script:totalFailures += 1
        }
    }

    if ($Suite -eq "all" -or $Suite -eq "v2") {
        try {
            Invoke-UnitTest -Label "v2 (test/test-v2.ts)" -ScriptRelPath "test/test-v2.ts" | Out-Null
        }
        catch {
            Write-Err "v2 raised: $($_.Exception.Message)"
            $script:totalFailures += 1
        }
    }
}

if ($runCross) {
    try {
        Invoke-CrossTest | Out-Null
    }
    catch {
        Write-Err "Cross test raised: $($_.Exception.Message)"
        $script:totalFailures += 1
    }
}

Write-Section "Summary"
Write-Info "runtime : $($script:runtime)"
Write-Info "passed  : $($script:totalPasses)"
Write-Info "failed  : $($script:totalFailures)"

if ($script:totalFailures -eq 0) {
    Write-Host ""
    Write-Ok "All tests passed."
    exit 0
}
else {
    Write-Host ""
    Write-Err "$($script:totalFailures) test suite(s) failed."
    exit 1
}