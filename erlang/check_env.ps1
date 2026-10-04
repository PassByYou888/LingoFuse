#Requires -Version 5.1
<#
.SYNOPSIS
    Environment diagnostic for the LingoFuse Erlang NIF binding.

.DESCRIPTION
    Collects a snapshot of every external dependency that the Erlang
    binding needs to build, load, and run:

        * Operating system and CPU architecture
        * PowerShell runtime
        * Erlang/OTP installation (erl, root_dir, erts version)
        * rebar3 launcher and version
        * C compilers on PATH (gcc, clang, cc, cl)
        * LingoFuse runtime library and its IPC dependencies
        * Project file layout
        * NIF build state (priv/lingofuse_nif.{dll,so})
        * Relevant environment variables
        * Dialyzer warning file, when present

    The report is printed to the console and also saved to a text
    file, so it can be pasted into an issue, an AI conversation, or
    a chat with a human maintainer.

    Every check is independent. A failure in one section never stops
    the others. The script always exits with code 0; it is a
    diagnostic tool, not a pass/fail gate.

.PARAMETER ReportPath
    Where to write the report. Defaults to check_env_report.txt in
    the directory that contains this script.

.PARAMETER NoSave
    Do not write the report file. The report is printed to the
    console only.

.PARAMETER Quiet
    Suppress console output. The report is only written to the file.
    Useful when the caller wants to capture the report and process
    it programmatically.

.EXAMPLE
    .\check_env.ps1
    Collect and print the full report, and save it to the default
    file.

.EXAMPLE
    .\check_env.ps1 -ReportPath D:\tmp\env.txt
    Write the report to a custom location.

.EXAMPLE
    .\check_env.ps1 -Quiet
    Save the report silently, without any console output.
#>

[CmdletBinding()]
param(
    [string]$ReportPath,
    [switch]$NoSave,
    [switch]$Quiet
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

# ============================================================================
# Report buffer and output helpers
# ============================================================================

$script:ReportLines = New-Object System.Collections.Generic.List[string]

function Emit {
    param(
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Text,
        [System.ConsoleColor]$Color = [System.ConsoleColor]::Gray
    )
    [void]$script:ReportLines.Add($Text)
    if (-not $Quiet) {
        Write-Host $Text -ForegroundColor $Color
    }
}

function Section {
    param([Parameter(Mandatory = $true)][string]$Title)
    Emit ''
    Emit ('=' * 72) -Color Cyan
    Emit ('  ' + $Title) -Color Cyan
    Emit ('=' * 72) -Color Cyan
}

function Info {
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Text)
    Emit ('         ' + $Text)
}

function Ok {
    param([Parameter(Mandatory = $true)][string]$Text)
    Emit ('  [OK]   ' + $Text) -Color Green
}

function Warn {
    param([Parameter(Mandatory = $true)][string]$Text)
    Emit ('  [WARN] ' + $Text) -Color Yellow
}

function Fail {
    param([Parameter(Mandatory = $true)][string]$Text)
    Emit ('  [FAIL] ' + $Text) -Color Red
}

function Skip {
    param([Parameter(Mandatory = $true)][string]$Text)
    Emit ('  [SKIP] ' + $Text) -Color DarkGray
}

# ============================================================================
# Small utilities
# ============================================================================

function Get-CommandPath {
    param([Parameter(Mandatory = $true)][string]$Name)
    $cmd = Get-Command $Name -ErrorAction SilentlyContinue
    if ($null -eq $cmd) { return $null }
    return $cmd.Source
}

function Invoke-Capture {
    param(
        [Parameter(Mandatory = $true)][string]$Exe,
        [Parameter(Mandatory = $true)][string[]]$Arguments
    )
    try {
        $out = & $Exe @Arguments 2>&1 | Out-String
        return $out.Trim()
    } catch {
        return $null
    }
}

function Get-FirstNonEmptyLine {
    param([string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { return $null }
    $lines = $Text -split "`r?`n" | Where-Object { $_.Trim() -ne '' }
    if ($lines.Count -eq 0) { return $null }
    return $lines[0].Trim()
}

# Search every directory listed on PATH for the given file names.
#
# The result is de-duplicated, both by directory and by resolved file
# path: a PATH that lists the same directory twice (which is common
# on Windows hosts where an installer appends its bin directory more
# than once) must not cause the same file to appear in the report two
# or more times.
function Test-FileInPathDirs {
    param([Parameter(Mandatory = $true)][string[]]$FileNames)

    $seenDirs = New-Object 'System.Collections.Generic.HashSet[string]' `
                       ([System.StringComparer]::OrdinalIgnoreCase)
    $seenFile = New-Object 'System.Collections.Generic.HashSet[string]' `
                       ([System.StringComparer]::OrdinalIgnoreCase)
    $hits = New-Object System.Collections.Generic.List[string]

    $pathValue = $env:PATH
    if ([string]::IsNullOrEmpty($pathValue)) { return $hits.ToArray() }

    $dirs = $pathValue.Split(';') | Where-Object { $_ -ne '' }
    foreach ($dir in $dirs) {
        $trimmed = $dir.TrimEnd('\', '/')
        if ([string]::IsNullOrEmpty($trimmed)) { continue }

        if (-not $seenDirs.Add($trimmed)) { continue }
        if (-not (Test-Path -Path $trimmed -PathType Container)) { continue }

        foreach ($name in $FileNames) {
            $candidate = Join-Path $trimmed $name
            if (Test-Path -Path $candidate -PathType Leaf) {
                if ($seenFile.Add($candidate)) {
                    [void]$hits.Add($candidate)
                }
            }
        }
    }
    return $hits.ToArray()
}

function Format-FileEntry {
    param([Parameter(Mandatory = $true)][string]$Path)
    try {
        $item = Get-Item -Path $Path -ErrorAction Stop
        $size = $item.Length
        $when = $item.LastWriteTime.ToString('yyyy-MM-dd HH:mm:ss')
        return ("{0}  ({1} bytes, {2})" -f $Path, $size, $when)
    } catch {
        return $Path
    }
}

# ============================================================================
# Script paths
# ============================================================================

$ScriptDir = $PSScriptRoot
if ([string]::IsNullOrEmpty($ScriptDir)) {
    $ScriptDir = (Get-Location).Path
}

if (-not $PSBoundParameters.ContainsKey('ReportPath') -or
    [string]::IsNullOrEmpty($ReportPath)) {
    $ReportPath = Join-Path $ScriptDir 'check_env_report.txt'
}

# ============================================================================
# Counters for the final summary
# ============================================================================

$script:CountOk   = 0
$script:CountWarn = 0
$script:CountFail = 0
$script:CountSkip = 0

function Bump-Ok   { $script:CountOk++ }
function Bump-Warn { $script:CountWarn++ }
function Bump-Fail { $script:CountFail++ }
function Bump-Skip { $script:CountSkip++ }

# ============================================================================
# Header
# ============================================================================

$now = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')

Emit ''
Emit '========================================================================'
Emit '  LingoFuse Erlang Binding - Environment Report'
Emit '========================================================================'
Info ('Generated       : ' + $now)
Info ('Script path     : ' + (Join-Path $ScriptDir 'check_env.ps1'))
Info ('Script dir      : ' + $ScriptDir)
Info ('Report file     : ' + $ReportPath)
Info ('Working dir     : ' + (Get-Location).Path)
Info ''
Info 'This report is designed to be pasted into an issue, an AI'
Info 'conversation, or a chat with a human maintainer. Nothing in'
Info 'this script modifies the system or the project.'

# ============================================================================
# 1. Operating system
# ============================================================================

Section '1. Operating system'

try {
    $os = [System.Environment]::OSVersion
    Info ('Platform        : ' + $os.Platform.ToString())
    Info ('Version string  : ' + $os.VersionString)
    Info ('Version number  : ' + $os.Version.ToString())
} catch {
    Warn 'could not read System.Environment.OSVersion'
    Bump-Warn
}

try {
    $arch = [System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture
    Info ('OS architecture : ' + $arch.ToString())
} catch {
    Info ('OS architecture : ' + $env:PROCESSOR_ARCHITECTURE)
}

try {
    $is64   = [System.Environment]::Is64BitOperatingSystem
    $proc64 = [System.Environment]::Is64BitProcess
    Info ('64-bit OS       : ' + $is64)
    Info ('64-bit process  : ' + $proc64)
} catch {
    Info '64-bit detection: unavailable'
}

try {
    $computer = $env:COMPUTERNAME
    if (-not [string]::IsNullOrEmpty($computer)) {
        Info ('Computer name   : ' + $computer)
    }
    $user = $env:USERNAME
    if (-not [string]::IsNullOrEmpty($user)) {
        Info ('User name       : ' + $user)
    }
} catch {
    Info 'host identification: unavailable'
}

# ============================================================================
# 2. PowerShell runtime
# ============================================================================

Section '2. PowerShell runtime'

try {
    $psv = $PSVersionTable.PSVersion
    Info ('PowerShell      : ' + $psv.ToString())
    if ($PSVersionTable.PSEdition) {
        Info ('Edition         : ' + $PSVersionTable.PSEdition)
    }
} catch {
    Warn 'could not read $PSVersionTable.PSVersion'
    Bump-Warn
}

try {
    Info ('.NET runtime    : ' + [System.Environment]::Version.ToString())
} catch {
    Info '.NET runtime    : unavailable'
}

$pwshPath = Get-CommandPath -Name 'pwsh'
if ($null -ne $pwshPath) {
    Info ('pwsh path       : ' + $pwshPath)
}
$winPsPath = Get-CommandPath -Name 'powershell'
if ($null -ne $winPsPath) {
    Info ('powershell path : ' + $winPsPath)
}

# ============================================================================
# 3. Erlang / OTP
# ============================================================================

Section '3. Erlang / OTP'

$erlPath = Get-CommandPath -Name 'erl'
if ($null -eq $erlPath) {
    Fail 'erl is not on PATH'
    Info 'Install Erlang/OTP 27 or later and add its bin directory'
    Info 'to PATH. See the README section "Setup".'
    Bump-Fail
} else {
    Ok ('erl found at ' + $erlPath)

    $otpRelease = Invoke-Capture -Exe $erlPath `
        -Arguments @('-noshell', '-eval',
                     'io:format("~s", [erlang:system_info(otp_release)]), halt().')
    if (-not [string]::IsNullOrEmpty($otpRelease)) {
        Info ('OTP release     : ' + $otpRelease)
        $major = 0
        [void][int]::TryParse(($otpRelease -replace '[^0-9]', ''), [ref]$major)
        if ($major -lt 27) {
            Fail ('OTP ' + $otpRelease + ' is older than the required OTP 27')
            Bump-Fail
        } else {
            Ok ('OTP version ' + $otpRelease + ' satisfies the OTP 27 requirement')
            Bump-Ok
        }
    } else {
        Warn 'could not query erlang:system_info(otp_release)'
        Bump-Warn
    }

    $ertsVer = Invoke-Capture -Exe $erlPath `
        -Arguments @('-noshell', '-eval',
                     'io:format("~s", [erlang:system_info(version)]), halt().')
    if (-not [string]::IsNullOrEmpty($ertsVer)) {
        Info ('erts version    : ' + $ertsVer)
    }

    $erlRoot = Invoke-Capture -Exe $erlPath `
        -Arguments @('-noshell', '-eval',
                     'io:format("~s", [code:root_dir()]), halt().')
    if (-not [string]::IsNullOrEmpty($erlRoot)) {
        Info ('ERL root        : ' + $erlRoot)

        if (-not [string]::IsNullOrEmpty($ertsVer)) {
            $ertsInclude = Join-Path $erlRoot ('erts-' + $ertsVer + '\include')
            if (Test-Path -Path $ertsInclude -PathType Container) {
                Ok ('erts include dir found at ' + $ertsInclude)
                Bump-Ok
            } else {
                Fail ('erts include dir missing at ' + $ertsInclude)
                Info 'The NIF cannot be compiled without erl_nif.h.'
                Bump-Fail
            }
        }
    }

    $erlcPath = Get-CommandPath -Name 'erlc'
    if ($null -ne $erlcPath) {
        Info ('erlc path       : ' + $erlcPath)
    }

    $escriptPath = Get-CommandPath -Name 'escript'
    if ($null -ne $escriptPath) {
        Info ('escript path    : ' + $escriptPath)
    } else {
        Warn 'escript is not on PATH'
        Bump-Warn
    }
}

# ============================================================================
# 4. rebar3
# ============================================================================

Section '4. rebar3'

$localRebarCmd = Join-Path $ScriptDir 'rebar3.cmd'
$localRebar    = Join-Path $ScriptDir 'rebar3'

if (Test-Path -Path $localRebarCmd -PathType Leaf) {
    Ok ('rebar3.cmd found at ' + $localRebarCmd)
    Bump-Ok
} else {
    Warn 'rebar3.cmd not found next to this script'
    Bump-Warn
}

if (Test-Path -Path $localRebar -PathType Leaf) {
    Ok ('rebar3 escript found at ' + $localRebar)
    Bump-Ok
} else {
    Warn 'rebar3 escript not found next to this script'
    Bump-Warn
}

$rebarOnPath = Get-CommandPath -Name 'rebar3'
if ($null -ne $rebarOnPath) {
    Info ('rebar3 on PATH  : ' + $rebarOnPath)
    $rebarVer = Invoke-Capture -Exe $rebarOnPath -Arguments @('version')
    if (-not [string]::IsNullOrEmpty($rebarVer)) {
        Info ('rebar3 version  : ' + (Get-FirstNonEmptyLine -Text $rebarVer))
    }
} else {
    Info 'rebar3 on PATH  : (not found; the local rebar3.cmd is used instead)'
}

# ============================================================================
# 5. C compilers
# ============================================================================

Section '5. C compilers'

$compilers = @(
    @{ Name = 'gcc';   VersionArgs = @('--version') },
    @{ Name = 'clang'; VersionArgs = @('--version') },
    @{ Name = 'cc';    VersionArgs = @('--version') },
    @{ Name = 'cl';    VersionArgs = @() }
)

$anyCompiler = $false

foreach ($c in $compilers) {
    $p = Get-CommandPath -Name $c.Name
    if ($null -eq $p) {
        Skip ($c.Name + ' not found on PATH')
        Bump-Skip
        continue
    }

    $anyCompiler = $true
    $verText = Invoke-Capture -Exe $p -Arguments $c.VersionArgs
    $first   = Get-FirstNonEmptyLine -Text $verText
    if ($null -eq $first) {
        Ok ($c.Name + ' found at ' + $p + ' (version unknown)')
    } else {
        Ok ($c.Name + ' found at ' + $p)
        Info ('          ' + $first)
    }
    Bump-Ok
}

if (-not $anyCompiler) {
    Warn 'No C compiler found. NIF compilation will be skipped.'
    Info 'Install MinGW-w64 (gcc), LLVM (clang), or use a VS Native'
    Info 'Tools command prompt that provides cl.exe.'
    Bump-Warn
}

# ============================================================================
# 6. LingoFuse runtime library
# ============================================================================

Section '6. LingoFuse runtime library'

$runtimeNames = @(
    'LingoFuse64.dll',
    'LingoFuse32.dll',
    'liblingofuse.so',
    'liblingofuse.dylib'
)

$runtimeHits = Test-FileInPathDirs -FileNames $runtimeNames

if ($runtimeHits.Count -eq 0) {
    Fail 'No LingoFuse runtime library found on PATH'
    Info ('Searched file names: ' + ($runtimeNames -join ', '))
    Info 'Add the LingoFuse Binary/ directory to PATH.'
    Bump-Fail
} else {
    Ok ($runtimeHits.Count.ToString() + ' runtime library file(s) found on PATH')
    foreach ($h in $runtimeHits) {
        Info (Format-FileEntry -Path $h)
    }
    Bump-Ok

    $ipcNames = @('z_ipc_64.dll', 'z_ipc_32.dll', 'libz_ipc.so')
    $ipcHits  = Test-FileInPathDirs -FileNames $ipcNames
    if ($ipcHits.Count -eq 0) {
        Warn 'No IPC dependency found on PATH (z_ipc_*.dll or libz_ipc.so)'
        Info 'The LingoFuse runtime library depends on it.'
        Bump-Warn
    } else {
        Ok ($ipcHits.Count.ToString() + ' IPC dependency file(s) found on PATH')
        foreach ($h in $ipcHits) {
            Info (Format-FileEntry -Path $h)
        }
        Bump-Ok
    }

    $mimallocNames = @('mimalloc64.dll', 'mimalloc32.dll', 'libmimalloc.so')
    $mimHits = Test-FileInPathDirs -FileNames $mimallocNames
    if ($mimHits.Count -eq 0) {
        Info 'mimalloc allocator not found (optional)'
    } else {
        Info ($mimHits.Count.ToString() + ' mimalloc file(s) found on PATH (optional)')
    }
}

# ============================================================================
# 7. Project layout
# ============================================================================

Section '7. Project layout'

$layoutChecks = @(
    @{ Path = 'rebar.config'; Kind = 'file'; Required = $true;  Label = 'rebar.config' },
    @{ Path = 'rebar.lock';   Kind = 'file'; Required = $false; Label = 'rebar.lock' },
    @{ Path = 'rebar3';       Kind = 'file'; Required = $true;  Label = 'rebar3 escript' },
    @{ Path = 'rebar3.cmd';   Kind = 'file'; Required = $false; Label = 'rebar3.cmd (Windows launcher)' },
    @{ Path = 'src';          Kind = 'dir';  Required = $true;  Label = 'src/' },
    @{ Path = 'test';         Kind = 'dir';  Required = $true;  Label = 'test/' },
    @{ Path = 'c_src';        Kind = 'dir';  Required = $true;  Label = 'c_src/' },
    @{ Path = 'cross';        Kind = 'dir';  Required = $false; Label = 'cross/' },
    @{ Path = 'priv';         Kind = 'dir';  Required = $false; Label = 'priv/' },
    @{ Path = '_build';       Kind = 'dir';  Required = $false; Label = '_build/' }
)

foreach ($item in $layoutChecks) {
    $fullPath = Join-Path $ScriptDir $item.Path
    if (Test-Path -Path $fullPath) {
        Ok ($item.Label + ' present')
        Bump-Ok
    } else {
        if ($item.Required) {
            Fail ($item.Label + ' missing')
            Bump-Fail
        } else {
            Skip ($item.Label + ' not present (optional)')
            Bump-Skip
        }
    }
}

# ============================================================================
# 8. Source files
# ============================================================================

Section '8. Source files'

$srcFiles  = @(Get-ChildItem -Path (Join-Path $ScriptDir 'src')   -Filter '*.erl'     -File -ErrorAction SilentlyContinue)
$testFiles = @(Get-ChildItem -Path (Join-Path $ScriptDir 'test')  -Filter '*.erl'     -File -ErrorAction SilentlyContinue)
$cFiles    = @(Get-ChildItem -Path (Join-Path $ScriptDir 'c_src') -Filter '*.c'       -File -ErrorAction SilentlyContinue)
$hFiles    = @(Get-ChildItem -Path (Join-Path $ScriptDir 'c_src') -Filter '*.h'       -File -ErrorAction SilentlyContinue)
$escripts  = @(Get-ChildItem -Path (Join-Path $ScriptDir 'cross') -Filter '*.escript' -File -ErrorAction SilentlyContinue)

Info ('src/*.erl        : ' + $srcFiles.Count)
foreach ($f in $srcFiles) { Info ('                    ' + $f.Name) }

Info ('test/*.erl       : ' + $testFiles.Count)
foreach ($f in $testFiles) { Info ('                    ' + $f.Name) }

Info ('c_src/*.c        : ' + $cFiles.Count)
foreach ($f in $cFiles) { Info ('                    ' + $f.Name) }

Info ('c_src/*.h        : ' + $hFiles.Count)
foreach ($f in $hFiles) { Info ('                    ' + $f.Name) }

Info ('cross/*.escript  : ' + $escripts.Count)
foreach ($f in $escripts) { Info ('                    ' + $f.Name) }

# ============================================================================
# 9. NIF build state
# ============================================================================

Section '9. NIF build state'

$privDir = Join-Path $ScriptDir 'priv'
$nifCandidates = @(
    (Join-Path $privDir 'lingofuse_nif.dll'),
    (Join-Path $privDir 'lingofuse_nif.so')
)

$nifFound = $false
foreach ($candidate in $nifCandidates) {
    if (Test-Path -Path $candidate -PathType Leaf) {
        Ok ('NIF present: ' + (Format-FileEntry -Path $candidate))
        $nifFound = $true
        Bump-Ok
    }
}

if (-not $nifFound) {
    Warn 'No NIF binary found under priv/'
    Info 'Run ".\build.ps1" (or ".\rebar3.cmd compile") to build it.'
    Bump-Warn
}

$ebinDir = Join-Path $ScriptDir '_build\default\lib\lingofuse\ebin'
if (Test-Path -Path $ebinDir -PathType Container) {
    $beamFiles = @(Get-ChildItem -Path $ebinDir -Filter '*.beam' -File -ErrorAction SilentlyContinue)
    Ok ('_build ebin present with ' + $beamFiles.Count + ' .beam file(s)')
    Bump-Ok
} else {
    Skip '_build ebin not present (project has not been compiled yet)'
    Bump-Skip
}

$pltFiles = @(Get-ChildItem -Path (Join-Path $ScriptDir '_build') -Filter '*.plt' -File -Recurse -ErrorAction SilentlyContinue)
if ($pltFiles.Count -gt 0) {
    Info ('Dialyzer PLT    : ' + $pltFiles[0].FullName)
    Info ('                  ' + (Format-FileEntry -Path $pltFiles[0].FullName))
} else {
    Info 'Dialyzer PLT    : not built yet'
}

$dialyzerWarnings = Join-Path $ScriptDir '_build\default\29.1.1.dialyzer_warnings'
if (Test-Path -Path $dialyzerWarnings -PathType Leaf) {
    Info ('dialyzer warnings file exists: ' + $dialyzerWarnings)
}

# ============================================================================
# 10. Environment variables
# ============================================================================

Section '10. Environment variables'

$knownVars = @(
    'LINGOFUSE_SKIP_NIF',
    'LINGOFUSE_REQUIRE_NATIVE',
    'LINGOFUSE_HOST',
    'LINGOFUSE_PORT',
    'LINGOFUSE_ENDPOINT',
    'LINGOFUSE_DEBUG',
    'LINGOFUSE_LOG_FILE',
    'LINGOFUSE_FORWARD_ONLY',
    'ERL_ROOT',
    'ERTS_VER'
)

$anyVar = $false
foreach ($var in $knownVars) {
    $value = [System.Environment]::GetEnvironmentVariable($var)
    if ($null -ne $value) {
        Info ($var + ' = ' + $value)
        $anyVar = $true
    }
}

if (-not $anyVar) {
    Info '(no LingoFuse-specific environment variables set)'
}

$pathValue = $env:PATH
if (-not [string]::IsNullOrEmpty($pathValue)) {
    $dirs = $pathValue.Split(';') | Where-Object { $_ -ne '' }
    Info ''
    Info ('PATH entries    : ' + $dirs.Count)
    $shown = [Math]::Min(5, $dirs.Count)
    for ($i = 0; $i -lt $shown; $i++) {
        Info ('  [' + $i + '] ' + $dirs[$i])
    }
    if ($dirs.Count -gt $shown) {
        Info ('  ... and ' + ($dirs.Count - $shown) + ' more')
    }
}

# ============================================================================
# 11. Summary
# ============================================================================

Section '11. Summary'

Emit ''
Emit ('  Checks passed   : ' + $script:CountOk)
Emit ('  Warnings        : ' + $script:CountWarn)
Emit ('  Failures        : ' + $script:CountFail)
Emit ('  Skipped         : ' + $script:CountSkip)
Emit ''

if ($script:CountFail -gt 0) {
    Emit '  Result: one or more required components are missing.' -Color Red
    Emit '          Review the [FAIL] lines above.' -Color Red
} elseif ($script:CountWarn -gt 0) {
    Emit '  Result: environment is usable, with warnings.' -Color Yellow
    Emit '          Review the [WARN] lines above.' -Color Yellow
} else {
    Emit '  Result: environment is ready.' -Color Green
}

# ============================================================================
# 12. How to use this report
# ============================================================================

Section '12. How to share this report'

Emit ''
Emit '  When asking for help, include the entire report file. It'
Emit '  contains every piece of information a maintainer or an AI'
Emit '  needs to diagnose a build or load failure:'
Emit ''
Emit ('      ' + $ReportPath)
Emit ''
Emit '  If you are pasting into an issue or an AI conversation, the'
Emit '  file can be attached as-is. No further context is required'
Emit '  for the tooling sections; only the specific symptom (which'
Emit '  command you ran and what it printed) needs to be described'
Emit '  separately.'
Emit ''

# ============================================================================
# Write the report file
# ============================================================================

if (-not $NoSave) {
    try {
        $absolutePath = $ReportPath
        if (-not [System.IO.Path]::IsPathRooted($absolutePath)) {
            $absolutePath = Join-Path (Get-Location).Path $absolutePath
        }

        $parentDir = Split-Path -Parent $absolutePath
        if (-not [string]::IsNullOrEmpty($parentDir) -and
            -not (Test-Path -Path $parentDir -PathType Container)) {
            [void](New-Item -ItemType Directory -Path $parentDir -Force)
        }

        $text = ($script:ReportLines -join [Environment]::NewLine)
        $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
        [System.IO.File]::WriteAllText($absolutePath, $text, $utf8NoBom)

        if (-not $Quiet) {
            Write-Host ''
            Write-Host ('Report saved to: ' + $absolutePath) -ForegroundColor Green
        }
    } catch {
        if (-not $Quiet) {
            Write-Host ''
            Write-Host ('Could not write report file: ' + $_.Exception.Message) -ForegroundColor Red
            Write-Host 'Use -NoSave to skip the file, or -ReportPath to pick another location.' -ForegroundColor Red
        }
    }
}

exit 0