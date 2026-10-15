#Requires -Version 7.0
<#
.SYNOPSIS
    Build script for lf_dart_bridge.dll on Windows (MSVC toolchain).

.DESCRIPTION
    Compiles lf_dart_bridge.c and dart_api_dl.c into lf_dart_bridge.dll
    using the MSVC compiler that ships with Visual Studio 2022.

    The script performs six steps:
      1. Verifies that all required source and header files are present.
      2. Locates vcvars64.bat (Visual Studio 2022 C++ x64 environment).
      3. Optionally cleans the obj/ intermediate directory.
      4. Invokes cl.exe to build the DLL.
      5. Inspects the DLL with dumpbin /exports and asserts that the
         expected number of lf_bridge_* symbols are exported, and that
         a list of critical symbols is present.
      6. Copies the DLL to both bridge/ and dart/ so that the Dart
         runtime and the test scripts can find it.

.PARAMETER Clean
    Remove the obj/ intermediate directory and the output DLL before
    building. Without this flag, an incremental build is attempted.

.PARAMETER SkipExportCheck
    Skip the dumpbin export verification step. Use only when dumpbin is
    unavailable (a rare edge case on stripped-down build agents).

.EXAMPLE
    .\build.ps1

.EXAMPLE
    .\build.ps1 -Clean

.NOTES
    All output is in English. See lf_dart_bridge.h for the full design
    rationale of the bridge.
#>
[CmdletBinding()]
param(
    [switch]$Clean,
    [switch]$SkipExportCheck
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# Paths and constants
# ---------------------------------------------------------------------------

$ScriptDir = $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($ScriptDir)) {
    Write-Host '[FATAL] $PSScriptRoot is empty; run this script from a file.' -ForegroundColor Red
    exit 1
}

$BridgeDir = $ScriptDir
$DartDir   = Split-Path $BridgeDir -Parent
$ObjDir    = Join-Path $BridgeDir 'obj'

$OutputDll       = Join-Path $BridgeDir 'lf_dart_bridge.dll'
$OutputDllInDart = Join-Path $DartDir   'lf_dart_bridge.dll'

$RequiredFiles = @(
    (Join-Path $BridgeDir 'lf_dart_bridge.h'),
    (Join-Path $BridgeDir 'lf_dart_bridge.c'),
    (Join-Path $BridgeDir 'dart_api.h'),
    (Join-Path $BridgeDir 'dart_api_dl.h'),
    (Join-Path $BridgeDir 'dart_api_dl.c'),
    (Join-Path $BridgeDir 'dart_native_api.h'),
    (Join-Path $BridgeDir 'dart_tools_api.h'),
    (Join-Path $BridgeDir 'dart_version.h'),
    (Join-Path $BridgeDir 'internal\dart_api_dl_impl.h'),
    (Join-Path $DartDir   'headers\LingoFuse.h')
)

# Minimum number of lf_bridge_* exports expected from the DLL.
$MinExportCount = 80

# Symbols that must always be present. These cover one entry point per
# major section of lf_dart_bridge.h, so a missing symbol here almost
# certainly means a structural problem in the .c implementation.
$CriticalExports = @(
    'lf_bridge_init',
    'lf_bridge_shutdown',
    'lf_bridge_is_initialized',
    'lf_bridge_create_data',
    'lf_bridge_free_data',
    'lf_bridge_get_p2p_uid',
    'lf_bridge_get_p2p_name',
    'lf_bridge_create_app',
    'lf_bridge_register_call',
    'lf_bridge_register_notify',
    'lf_bridge_register_p2p_call',
    'lf_bridge_complete',
    'lf_bridge_prepare_done',
    'lf_bridge_call',
    'lf_bridge_call_async',
    'lf_bridge_uid_call',
    'lf_bridge_p2pname_call',
    'lf_bridge_set_opt_quiet',
    'lf_bridge_get_opt_quiet',
    'lf_bridge_set_network_event',
    'lf_bridge_stats_json'
)

# ---------------------------------------------------------------------------
# Output helpers
# ---------------------------------------------------------------------------

function Write-Section([string]$Text) {
    Write-Host ''
    Write-Host ('=' * 66) -ForegroundColor Cyan
    Write-Host "  $Text" -ForegroundColor Cyan
    Write-Host ('=' * 66) -ForegroundColor Cyan
}
function Write-Ok([string]$Text)   { Write-Host "  [OK]   $Text" -ForegroundColor Green }
function Write-Warn([string]$Text) { Write-Host "  [WARN] $Text" -ForegroundColor Yellow }
function Write-Fail([string]$Text) { Write-Host "  [FAIL] $Text" -ForegroundColor Red }
function Write-Info([string]$Text) { Write-Host "         $Text" -ForegroundColor Gray }

# ---------------------------------------------------------------------------
# Step 1 -- Verify required files
# ---------------------------------------------------------------------------

Write-Section 'LingoFuse Dart Bridge Build (Windows / MSVC)'

Write-Host '  Step 1: verifying required files' -ForegroundColor White
$missing = @()
foreach ($f in $RequiredFiles) {
    if (-not (Test-Path $f)) { $missing += $f }
}

if ($missing.Count -gt 0) {
    foreach ($f in $missing) { Write-Fail "missing: $f" }
    Write-Host ''
    Write-Info 'Ensure all Dart SDK headers have been copied into bridge/, and'
    Write-Info 'that headers/LingoFuse.h is present in the parent directory.'
    Write-Info 'See README.md, section "Compiling the C bridge DLL".'
    exit 1
}
Write-Ok "all $($RequiredFiles.Count) required files present"

# ---------------------------------------------------------------------------
# Step 2 -- Locate vcvars64.bat
# ---------------------------------------------------------------------------

Write-Host ''
Write-Host '  Step 2: locating vcvars64.bat' -ForegroundColor White

$vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
$vcvars  = $null

if (Test-Path $vswhere) {
    $installPath = & $vswhere -latest -products * `
        -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 `
        -property installationPath 2>$null

    if (-not [string]::IsNullOrWhiteSpace($installPath)) {
        $candidate = Join-Path $installPath 'VC\Auxiliary\Build\vcvars64.bat'
        if (Test-Path $candidate) { $vcvars = $candidate }
    }
}

if (-not $vcvars) {
    $roots = @(
        "$env:ProgramFiles\Microsoft Visual Studio\2022",
        "${env:ProgramFiles(x86)}\Microsoft Visual Studio\2022"
    )
    foreach ($root in $roots) {
        if (-not (Test-Path $root)) { continue }
        foreach ($edition in @('Enterprise', 'Professional', 'Community', 'BuildTools')) {
            $candidate = Join-Path $root "$edition\VC\Auxiliary\Build\vcvars64.bat"
            if (Test-Path $candidate) { $vcvars = $candidate; break }
        }
        if ($vcvars) { break }
    }
}

if (-not $vcvars) {
    Write-Fail 'vcvars64.bat not found'
    Write-Info 'Visual Studio 2022 with the "Desktop development with C++"'
    Write-Info 'workload is required. Install it via the Visual Studio Installer.'
    exit 1
}
Write-Ok "found: $vcvars"

# ---------------------------------------------------------------------------
# Step 3 -- Optional clean
# ---------------------------------------------------------------------------

Write-Host ''
Write-Host '  Step 3: cleaning previous build' -ForegroundColor White

if ($Clean) {
    if (Test-Path $ObjDir) {
        Remove-Item $ObjDir -Recurse -Force
        Write-Ok "removed $ObjDir"
    } else {
        Write-Info 'no obj/ directory to remove'
    }
    if (Test-Path $OutputDll) {
        Remove-Item $OutputDll -Force
        Write-Ok "removed $OutputDll"
    }
    if (Test-Path $OutputDllInDart) {
        Remove-Item $OutputDllInDart -Force
        Write-Ok "removed $OutputDllInDart"
    }
} else {
    Write-Info 'clean skipped (pass -Clean to force a full rebuild)'
}

# ---------------------------------------------------------------------------
# Step 4 -- Compile
# ---------------------------------------------------------------------------

Write-Host ''
Write-Host '  Step 4: compiling lf_dart_bridge.dll' -ForegroundColor White

if (-not (Test-Path $ObjDir)) {
    New-Item -ItemType Directory -Path $ObjDir | Out-Null
}

# Build a temporary .bat that runs inside a clean MSVC environment.
# Writing the batch file to disk is more reliable than fighting with
# PowerShell <-> cmd.exe quoting on a complex command line.
$tempBat = Join-Path $env:TEMP ('lf_build_' + [guid]::NewGuid().ToString('N') + '.bat')

$clArgs = @(
    '/nologo',
    '/O2',
    '/LD',
    '/MD',
    '/W3',
    '/wd4100',            # unused parameter (some stubs intentionally ignore args)
    '/I.',
    '/I..\headers',
    'lf_dart_bridge.c',
    'dart_api_dl.c',
    '/Fe:lf_dart_bridge.dll',
    '/Fo:obj/'
) -join ' '

$batContent = @"
@echo off
call "$vcvars"
if errorlevel 1 ( echo [FATAL] vcvars64.bat failed & exit /b 1 )
cl.exe $clArgs
if errorlevel 1 ( echo [FATAL] cl.exe failed & exit /b 1 )
exit /b 0
"@

Set-Content -Path $tempBat -Value $batContent -Encoding ASCII

$compileOk = $false
try {
    Push-Location $BridgeDir
    try {
        & cmd.exe /c $tempBat
        $compileOk = ($LASTEXITCODE -eq 0)
    } finally {
        Pop-Location
    }
} finally {
    Remove-Item $tempBat -Force -ErrorAction SilentlyContinue
}

if (-not $compileOk) {
    Write-Fail 'compilation failed'
    exit 1
}

if (-not (Test-Path $OutputDll)) {
    Write-Fail "cl.exe reported success but $OutputDll does not exist"
    exit 1
}

$dllSize = (Get-Item $OutputDll).Length
Write-Ok "built: $OutputDll ($dllSize bytes)"

# ---------------------------------------------------------------------------
# Step 5 -- Verify exports with dumpbin
# ---------------------------------------------------------------------------

if (-not $SkipExportCheck) {
    Write-Host ''
    Write-Host '  Step 5: verifying exported symbols (dumpbin)' -ForegroundColor White

    $dumpbinBat = Join-Path $env:TEMP ('lf_dump_' + [guid]::NewGuid().ToString('N') + '.bat')
    $dumpbinContent = @"
@echo off
call "$vcvars"
if errorlevel 1 exit /b 1
dumpbin /nologo /exports lf_dart_bridge.dll
exit /b 0
"@
    Set-Content -Path $dumpbinBat -Value $dumpbinContent -Encoding ASCII

    $dumpbinOutput = $null
    try {
        Push-Location $BridgeDir
        try {
            $dumpbinOutput = & cmd.exe /c $dumpbinBat 2>&1
        } finally {
            Pop-Location
        }
    } finally {
        Remove-Item $dumpbinBat -Force -ErrorAction SilentlyContinue
    }

    if ($null -eq $dumpbinOutput) {
        Write-Warn 'dumpbin produced no output; skipping export check'
    } else {
        # dumpbin /exports emits lines of the form:
        #     <ordinal>  <hint>  <rva>  <name>
        # The regex below matches exactly those lines for lf_bridge_*.
        $exportLines = $dumpbinOutput | Select-String -Pattern '^\s*\d+\s+[0-9A-Fa-f]+\s+[0-9A-Fa-f]+\s+(lf_bridge_\w+)\s*$'
        $exportCount = $exportLines.Count

        if ($exportCount -ge $MinExportCount) {
            Write-Ok "exported $exportCount lf_bridge_* symbols (minimum: $MinExportCount)"
        } else {
            Write-Fail "only $exportCount lf_bridge_* symbols exported; expected at least $MinExportCount"
            Write-Info 'The bridge header may declare more functions than the .c implements.'
            Write-Info 'Re-check lf_dart_bridge.c against lf_dart_bridge.h.'
            exit 1
        }

        # Spot-check the critical exports.
        $missingExports = @()
        foreach ($name in $CriticalExports) {
            if (-not ($dumpbinOutput | Select-String -Pattern ("\b" + [regex]::Escape($name) + "\b") -Quiet)) {
                $missingExports += $name
            }
        }
        if ($missingExports.Count -gt 0) {
            foreach ($name in $missingExports) {
                Write-Fail "critical export missing: $name"
            }
            exit 1
        }
        Write-Ok "all $($CriticalExports.Count) critical exports present"
    }
} else {
    Write-Host ''
    Write-Host '  Step 5: export verification skipped (-SkipExportCheck)' -ForegroundColor White
}

# ---------------------------------------------------------------------------
# Step 6 -- Copy to dart/ parent directory
# ---------------------------------------------------------------------------

Write-Host ''
Write-Host '  Step 6: copying to dart/ parent directory' -ForegroundColor White

if ($BridgeDir -eq $DartDir) {
    Write-Warn 'bridge/ and dart/ are the same directory; copy skipped'
} else {
    Copy-Item -Path $OutputDll -Destination $OutputDllInDart -Force
    Write-Ok "copied to: $OutputDllInDart"
}

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------

Write-Section 'Build complete'
Write-Host ''
Write-Ok "DLL  : $OutputDll"
Write-Ok "copy : $OutputDllInDart"
Write-Host ''
Write-Info 'Next steps:'
Write-Info '  1. cd ..'
Write-Info '  2. dart test                      # run the offline test suite'
Write-Info '  3. dart run bin/lf_probe.dart     # minimal load probe'
Write-Host ''

exit 0