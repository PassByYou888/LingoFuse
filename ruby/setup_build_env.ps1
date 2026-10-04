# =============================================================================
#  setup_build_env.ps1 — Build and install the lingofuse_ext C extension.
# -----------------------------------------------------------------------------
#  This script is PORTABLE across Windows machines. It uses no hard-coded
#  paths: the project root is $PSScriptRoot, and every external tool is
#  located at runtime.
#
#  It cannot, however, install its own prerequisites. The target machine
#  must already have:
#
#    1. Windows 10 / 11 / Server 2019+ with PowerShell 5.0 or newer.
#    2. RubyInstaller (x64-mingw-ucrt) with DevKit, on PATH.
#       See INSTALL_DEPENDENCIES.md sections 2 and 3.
#    3. A GNU Make, provided by the DevKit's msys64.
#       See INSTALL_DEPENDENCIES.md section 3.2.
#
#  If a prerequisite is missing, the script fails FAST with a message
#  that names the missing item and points to the relevant documentation
#  section. This is deliberate: a late failure (for example, "No GNU
#  Make found") is misleading when the real cause is a missing Ruby.
#
#  When every prerequisite is satisfied, the script proceeds
#  automatically through:
#
#    1. Locating a GNU Make.
#    2. Preparing PATH for the duration of the script.
#    3. Running `ruby extconf.rb`.
#    4. Running `make`.
#    5. Installing the built artifact into lib/ (STRICT: a failed copy
#       ABORTS the script, so a stale .so can never be mistaken for a
#       fresh one).
#    6. Running a load test.
#
#  Exit codes:
#
#      0   the extension was built AND installed into lib/
#      1   a prerequisite was missing, or a build step failed
#
#  Usage:
#
#      cd D:\CoreLibrary\LingoFuse\ruby
#      powershell -ExecutionPolicy Bypass -File setup_build_env.ps1
#
# =============================================================================

$ErrorActionPreference = 'Continue'

# =============================================================================
# Reporter
# =============================================================================

function Write-Section {
    param([string]$Title)
    Write-Host ''
    Write-Host ('=' * 72)
    Write-Host $Title
    Write-Host ('=' * 72)
}

function Write-Ok   { param([string]$m) Write-Host "  [OK]   $m" }
function Write-Fail { param([string]$m) Write-Host "  [FAIL] $m" }
function Write-Warn { param([string]$m) Write-Host "  [WARN] $m" }
function Write-Info { param([string]$m) Write-Host "         $m" }

# =============================================================================
# Section 0 — Prerequisites
# -----------------------------------------------------------------------------
#  This section fails FAST. Every check below must pass before the
#  script attempts to build anything. This keeps error messages
#  accurate: a missing Ruby is reported as "ruby is not on PATH", not
#  as "No GNU Make found" (which would be the downstream symptom).
# =============================================================================

Write-Section '0. Prerequisites'

# --- 0a. Non-Windows guard -------------------------------------------------
#
# The script targets Windows: it looks for *.exe executables and uses
# Windows-style path separators. On PowerShell Core running on Linux or
# macOS, refuse to run rather than fail with a cryptic error later.
#
# [System.Environment]::OSVersion.Platform is used instead of
# $PSVersionTable.Platform because the latter is inconsistent:
#
#   Windows PowerShell 5.1      : Win32NT
#   PowerShell Core 6+ on Win   : Win32
#   PowerShell Core on Unix     : Unix
#
# [System.Environment]::OSVersion.Platform returns the same value on
# every version: Win32NT on Windows, Unix on Linux / macOS.

$osPlatform = [System.Environment]::OSVersion.Platform
if ($osPlatform -ne 'Win32NT') {
    Write-Fail "This script targets Windows; detected platform: $osPlatform."
    Write-Info 'On Linux or macOS, build the extension manually:'
    Write-Info '    cd ext/lingofuse_ext'
    Write-Info '    ruby extconf.rb'
    Write-Info '    make'
    exit 1
}

# --- 0b. PowerShell version ------------------------------------------------

if ($PSVersionTable.PSVersion.Major -lt 5) {
    Write-Fail "PowerShell $($PSVersionTable.PSVersion) is too old."
    Write-Info 'PowerShell 5.0 or newer is required.'
    exit 1
}
Write-Ok "PowerShell $($PSVersionTable.PSVersion)"

# --- 0c. Script location ---------------------------------------------------
#
# $PSScriptRoot is set whenever the script is run as a file. It is empty
# when the script is dot-sourced or eval'd from an inline command.
# Everything downstream depends on it.

if (-not $PSScriptRoot) {
    Write-Fail '$PSScriptRoot is empty.'
    Write-Info 'Run this script as a file:'
    Write-Info '    powershell -ExecutionPolicy Bypass -File setup_build_env.ps1'
    exit 1
}
Write-Ok "Script directory: $PSScriptRoot"

# --- 0d. Source tree -------------------------------------------------------
#
# ext/lingofuse_ext/ must exist and contain both source files. A missing
# directory usually means the user copied only the script, or is running
# it from the wrong directory.

$extDir = Join-Path $PSScriptRoot 'ext\lingofuse_ext'
if (-not (Test-Path $extDir)) {
    Write-Fail "Extension directory not found: $extDir"
    Write-Info 'Run this script from the ruby/ directory of a LingoFuse checkout.'
    Write-Info 'The directory ext/lingofuse_ext/ must exist and contain:'
    Write-Info '    extconf.rb'
    Write-Info '    lingofuse_ext.c'
    exit 1
}

$extconfPath = Join-Path $extDir 'extconf.rb'
if (-not (Test-Path $extconfPath)) {
    Write-Fail "extconf.rb not found: $extconfPath"
    exit 1
}

$cSourcePath = Join-Path $extDir 'lingofuse_ext.c'
if (-not (Test-Path $cSourcePath)) {
    Write-Fail "lingofuse_ext.c not found: $cSourcePath"
    exit 1
}
Write-Ok 'Extension source tree found.'

# --- 0e. Ruby on PATH ------------------------------------------------------
#
# Ruby is checked before anything else, because every later step depends
# on it. If ruby is missing, the error message must say so, not "No GNU
# Make found" (which is what would happen if Section 1 ran first).

$rubyCmd = Get-Command ruby -ErrorAction SilentlyContinue
if (-not $rubyCmd) {
    Write-Fail 'ruby is not on PATH.'
    Write-Info 'Install RubyInstaller + DevKit, then REOPEN PowerShell.'
    Write-Info 'See INSTALL_DEPENDENCIES.md sections 2 and 3.'
    exit 1
}
Write-Ok "Ruby: $($rubyCmd.Source)"

# --- 0f. Ruby sanity check -------------------------------------------------
#
# Verify that the ruby on PATH actually runs. This catches a broken
# symlink, a Windows Store stub, or a PATH entry pointing at a file that
# is not the Ruby interpreter.

$rubyVersion = (& ruby -v 2>&1) -join ' '
if ($LASTEXITCODE -ne 0 -or -not ($rubyVersion -match 'ruby')) {
    Write-Fail "ruby is on PATH but does not run: $rubyVersion"
    Write-Info 'Reinstall RubyInstaller and reopen PowerShell.'
    Write-Info 'See INSTALL_DEPENDENCIES.md section 2.'
    exit 1
}
Write-Ok "Ruby version: $rubyVersion"

# --- 0g. gcc on PATH -------------------------------------------------------
#
# gcc is provided by the Ruby DevKit (msys64/mingw64/bin). If it is not
# on PATH, either the DevKit was not installed, or its bin directory is
# not on PATH.

$gccCmd = Get-Command gcc -ErrorAction SilentlyContinue
if (-not $gccCmd) {
    Write-Fail 'gcc is not on PATH.'
    Write-Info 'This usually means the Ruby DevKit is not installed,'
    Write-Info 'or its bin/ directory is not on PATH.'
    Write-Info 'See INSTALL_DEPENDENCIES.md section 3.'
    exit 1
}
$gccVersion = (& gcc --version 2>&1 | Select-Object -First 1) -join ' '
Write-Ok "gcc: $($gccCmd.Source)"
Write-Info "     $gccVersion"

# --- 0h. mkmf availability -------------------------------------------------
#
# mkmf ships with the Ruby standard library, but its own checks require
# a working C toolchain. If mkmf cannot be loaded, extconf.rb is
# guaranteed to fail, so this check catches the problem earlier.

$mkmfCheck = (& ruby -e "begin; require 'mkmf'; puts 'MKMK_OK'; rescue LoadError => e; puts 'MKMK_MISSING ' + e.message; end" 2>&1) -join ' '
if ($mkmfCheck -notmatch 'MKMK_OK') {
    Write-Fail "mkmf is not available: $mkmfCheck"
    Write-Info 'The Ruby DevKit is required to build C extensions.'
    Write-Info 'See INSTALL_DEPENDENCIES.md section 3.'
    exit 1
}
Write-Ok 'mkmf is available.'

# =============================================================================
# Section 1 — Locate a GNU Make
# =============================================================================

Write-Section '1. Locating a GNU Make'

$foreignPattern = 'Embarcadero|Borland|bcc32|CodeGear'

function Test-GnuMake {
    param([string]$Path, [string]$ExeName)
    if (-not (Test-Path $Path)) { return $null }
    $exePath = Join-Path $Path $ExeName
    if (-not (Test-Path $exePath)) { return $null }

    try {
        $v = (& $exePath --version 2>&1 | Select-Object -First 1) -join ' '
    } catch {
        return $null
    }
    if ($v -match 'GNU Make') {
        return [PSCustomObject]@{
            Exe     = $exePath
            Name    = $ExeName
            Version = $v
        }
    }
    return $null
}

$candidates = New-Object System.Collections.Generic.List[string]

# Every directory on PATH except known-foreign ones.
foreach ($dir in ($env:PATH -split ';')) {
    if (-not $dir) { continue }
    if ($dir -match $foreignPattern) { continue }
    $candidates.Add($dir) | Out-Null
}

# gcc's own directory (usually DevKit's mingw64/bin).
$gccDir = Split-Path $gccCmd.Source -Parent
if ($gccDir) {
    $candidates.Insert(0, $gccDir)
}

# Ruby's msys64 directories (highest priority).
$rubyBin = (& ruby -e "require 'rbconfig'; puts RbConfig::CONFIG['bindir']" 2>&1) -join ' '
if ($rubyBin) {
    $rubyRoot = Split-Path $rubyBin -Parent
    $candidates.Insert(0, (Join-Path $rubyRoot 'msys64\usr\bin'))
    $candidates.Insert(0, (Join-Path $rubyRoot 'msys64\mingw64\bin'))
}

# RI_DEVKIT, if set by the Ruby installer.
if ($env:RI_DEVKIT) {
    $candidates.Insert(0, $env:RI_DEVKIT)
    $candidates.Insert(0, (Join-Path $env:RI_DEVKIT 'bin'))
}

# Deduplicate while preserving order.
$seen = New-Object System.Collections.Generic.HashSet[string]
$uniqueCandidates = New-Object System.Collections.Generic.List[string]
foreach ($c in $candidates) {
    $normalized = $c.TrimEnd('\', '/')
    if ($seen.Add($normalized)) {
        $uniqueCandidates.Add($normalized) | Out-Null
    }
}

$foundMake = $null
$makeDir = $null

foreach ($dir in $uniqueCandidates) {
    foreach ($name in @('make.exe', 'mingw32-make.exe', 'gmake.exe')) {
        $result = Test-GnuMake -Path $dir -ExeName $name
        if ($result) {
            $foundMake = $result
            $makeDir = $dir
            break
        }
    }
    if ($foundMake) { break }
}

if (-not $foundMake) {
    Write-Fail 'No GNU Make found.'
    Write-Info 'GNU Make is provided by the Ruby DevKit (msys64\usr\bin).'
    Write-Info ''
    Write-Info 'Searched the following directories:'
    foreach ($dir in $uniqueCandidates) {
        Write-Info "  $dir"
    }
    Write-Info ''
    Write-Info 'Common fixes:'
    Write-Info '  1. Ensure the Ruby DevKit is installed.'
    Write-Info '  2. Prepend the DevKit bin directory to PATH for this session:'
    Write-Info '       $env:PATH = "C:\Ruby40-x64\msys64\usr\bin;" + $env:PATH'
    Write-Info '  3. Or set RI_DEVKIT to the msys64 root:'
    Write-Info '       $env:RI_DEVKIT = "C:\Ruby40-x64\msys64"'
    Write-Info ''
    Write-Info 'See INSTALL_DEPENDENCIES.md section 3.2.'
    exit 1
}

Write-Ok 'GNU Make found:'
Write-Info "  path    : $($foundMake.Exe)"
Write-Info "  version : $($foundMake.Version)"

# =============================================================================
# Section 2 — Prepare PATH for this script
# =============================================================================

Write-Section '2. Reordering PATH'

$newPathParts = @($makeDir)

# If the make directory is msys64/usr/bin, also prepend msys64/mingw64/bin
# so that gcc and its runtime DLLs resolve consistently.
if ($makeDir -match '(.*\\msys64\\usr\\bin)$') {
    $msysRoot = $Matches[1] -replace '\\usr\\bin$', ''
    $mingwBin = Join-Path $msysRoot 'mingw64\bin'
    if (Test-Path $mingwBin) {
        $newPathParts += $mingwBin
    }
}

$oldPath = $env:PATH
$env:PATH = ($newPathParts -join ';') + ';' + $oldPath
Write-Ok 'PATH updated for this script.'

$makeCmd = Get-Command make -ErrorAction SilentlyContinue
if ($makeCmd) {
    Write-Info "make now resolves to : $($makeCmd.Source)"
} else {
    Write-Warn 'make is not yet on PATH; the build step will call the full path.'
}

# =============================================================================
# Section 3 — LINGOFUSE_LIB_PATH (informational)
# -----------------------------------------------------------------------------
#  This variable is NOT required to build the extension. It is only
#  used by the runtime binding, and even then it is optional: binding.rb
#  automatically searches several standard locations. This section is
#  purely informational.
# =============================================================================

Write-Section '3. LingoFuse native library path (informational)'

if ($env:LINGOFUSE_LIB_PATH) {
    Write-Ok "LINGOFUSE_LIB_PATH = $env:LINGOFUSE_LIB_PATH"
} else {
    Write-Info 'LINGOFUSE_LIB_PATH is not set in this shell.'
    Write-Info 'This is OPTIONAL. It is not needed for the build, and the'
    Write-Info 'runtime binding searches standard locations automatically.'
    Write-Info 'Set it only if the DLLs are stored outside the project:'
    Write-Info '    $env:LINGOFUSE_LIB_PATH = "D:\path\to\binary"'
}

# =============================================================================
# Section 4 — extconf.rb
# =============================================================================

Write-Section '4. extconf.rb'

Push-Location $extDir
try {
    $staleMakefile = Join-Path $extDir 'Makefile'
    if (Test-Path $staleMakefile) {
        try {
            Remove-Item $staleMakefile -Force -ErrorAction Stop
            Write-Ok 'Removed stale Makefile.'
        } catch {
            Write-Fail "Cannot remove stale Makefile: $($_.Exception.Message)"
            Write-Info 'Close any editor that has it open and re-run.'
            exit 1
        }
    }

    Write-Info 'Running: ruby extconf.rb'
    $extconfOutput = (& ruby extconf.rb 2>&1) -join "`n"
    if ($LASTEXITCODE -ne 0) {
        Write-Fail 'ruby extconf.rb failed.'
        Write-Info ''
        Write-Info 'Output:'
        foreach ($line in ($extconfOutput -split "`n")) {
            Write-Info "  $line"
        }
        Write-Info ''
        Write-Info 'See INSTALL_DEPENDENCIES.md section 3 for DevKit setup.'
        exit 1
    }
    Write-Ok 'extconf.rb completed.'
    foreach ($line in ($extconfOutput -split "`n")) {
        if ($line.Trim()) { Write-Info $line }
    }

    if (-not (Test-Path $staleMakefile)) {
        Write-Fail 'extconf.rb did not produce a Makefile.'
        exit 1
    }
    $mfHead = (Get-Content $staleMakefile -TotalCount 10) -join ' '
    if ($mfHead -match 'Embarcadero|Borland') {
        Write-Fail 'The generated Makefile is not a mkmf output.'
        Write-Info 'An Embarcadero / Borland Make may be shadowing the DevKit one.'
        Write-Info 'See INSTALL_DEPENDENCIES.md section 3.2.'
        exit 1
    }
    Write-Ok 'A fresh mkmf-style Makefile is in place.'

    # =================================================================
    # Section 5 — Build
    # =================================================================

    Write-Section '5. make'

    Write-Info "Running: $($foundMake.Exe)"
    $makeOutput = (& $foundMake.Exe 2>&1) -join "`n"
    $makeExit = $LASTEXITCODE

    foreach ($line in ($makeOutput -split "`n")) {
        if ($line.Trim()) { Write-Info $line }
    }

    if ($makeExit -ne 0) {
        Write-Fail "make exited with code $makeExit."
        Write-Info ''
        Write-Info 'Common causes:'
        Write-Info '  * The C source has a compile error (see messages above).'
        Write-Info '  * A wrong Make is being used (must be GNU Make).'
        Write-Info '  * A missing header (pthread.h, ruby/thread.h).'
        Write-Info ''
        Write-Info 'See BUILD_EXTENSION.md section 5 for diagnosis.'
        exit 1
    }
    Write-Ok 'make completed successfully.'

    # =================================================================
    # Section 6 — Artifact + strict install
    # -----------------------------------------------------------------
    #  The install step is STRICT: any failure aborts the script with
    #  exit code 1. This is deliberate. A previous version reported
    #  [OK] even when Copy-Item failed (typically because the
    #  destination .so was locked by a running Ruby process), and then
    #  ran a load test against the STALE file in lib/, producing a
    #  false-positive success message.
    # =================================================================

    Write-Section '6. Artifact'

    $artifacts = @(
        Get-ChildItem -Path $extDir -File |
            Where-Object {
                $_.Extension -in @('.so', '.dll') -and
                $_.Name -like 'lingofuse_ext*'
            }
    )

    if ($artifacts.Count -eq 0) {
        Write-Fail 'No lingofuse_ext.so / .dll was produced.'
        Write-Info 'The Makefile ran, but did not produce an artifact.'
        Write-Info 'Check the make output above.'
        exit 1
    }

    foreach ($a in $artifacts) {
        Write-Ok "Built: $($a.Name) ($($a.Length) bytes)"
    }

    # Prefer the .so produced by MinGW; fall back to any artifact.
    $soFile = $artifacts |
        Where-Object { $_.Extension -eq '.so' } |
        Select-Object -First 1
    if (-not $soFile) {
        $soFile = $artifacts | Select-Object -First 1
    }

    $destLib = Join-Path $PSScriptRoot 'lib'
    if (-not (Test-Path $destLib)) {
        New-Item -ItemType Directory -Path $destLib | Out-Null
    }

    $destPath = Join-Path $destLib $soFile.Name

    # -----------------------------------------------------------------
    # Step 6a — remove any stale copy of the destination file.
    #
    # On Windows, a .so that has been loaded into a process cannot be
    # overwritten while that process is alive. Removing the file first
    # produces a clearer error than overwriting it, and lets us give
    # the user a precise remediation message.
    # -----------------------------------------------------------------
    if (Test-Path $destPath) {
        try {
            Remove-Item $destPath -Force -ErrorAction Stop
        } catch {
            Write-Fail "Cannot replace $destPath."
            Write-Info 'The file is locked by another process.'
            Write-Info ''
            Write-Info 'Close every Ruby session that may have loaded it:'
            Write-Info '  * running tests (test/test_*.rb)'
            Write-Info '  * irb / pry shells'
            Write-Info '  * VS Code rdbg debug sessions'
            Write-Info '  * any background service that required lingofuse_ext'
            Write-Info ''
            Write-Info 'To list running Ruby processes:'
            Write-Info '    Get-Process ruby -ErrorAction SilentlyContinue'
            Write-Info ''
            Write-Info 'Then re-run this script.'
            exit 1
        }
    }

    # -----------------------------------------------------------------
    # Step 6b — copy the freshly built artifact into lib/.
    # -----------------------------------------------------------------
    try {
        Copy-Item $soFile.FullName $destPath -Force -ErrorAction Stop
    } catch {
        Write-Fail "Copy-Item failed: $($_.Exception.Message)"
        exit 1
    }

    # -----------------------------------------------------------------
    # Step 6c — verify the copied file matches the source.
    #
    # A size check catches the rare case where the copy succeeded from
    # PowerShell's point of view but produced a truncated file.
    # -----------------------------------------------------------------
    $srcSize  = (Get-Item $soFile.FullName).Length
    $destSize = (Get-Item $destPath).Length
    if ($srcSize -ne $destSize) {
        Write-Fail "Installed file size mismatch (source=$srcSize, dest=$destSize)."
        exit 1
    }

    Write-Ok "Installed: $destPath ($destSize bytes)"

    # =================================================================
    # Section 7 — Load test
    # -----------------------------------------------------------------
    #  The load test runs only after a verified install, so the library
    #  it loads is guaranteed to be the one just built.
    #
    #  The test is written as a temporary .rb file and executed with
    #  `ruby -I lib <file>`, which avoids two PowerShell pitfalls:
    #  double-quote stripping on the command line, and `#{}`
    #  interpolation in here-strings.
    # =================================================================

    Write-Section '7. Load test'

    $loadScript = Join-Path $env:TEMP ('lf_load_test_' + [System.Guid]::NewGuid().ToString('N') + '.rb')
    $scriptBody = @'
begin
  require 'lingofuse_ext'
  nb = LingoFuse::NativeBridge
  if nb.respond_to?(:create_ref) && nb.respond_to?(:process_all) && nb.respond_to?(:test_invoke_from_native_thread)
    puts 'LOADED: true true true'
  elsif nb.respond_to?(:create_ref) && nb.respond_to?(:process_all)
    puts 'LOADED: true true false'
  else
    puts 'LOADED: partial'
  end
rescue LoadError => e
  puts 'LOAD_ERROR: ' + e.message
end
'@
    Set-Content -Path $loadScript -Value $scriptBody -Encoding ASCII

    try {
        $loadOutput = (& ruby -I $destLib $loadScript 2>&1) -join "`n"
        foreach ($line in ($loadOutput -split "`n")) {
            if ($line.Trim()) { Write-Info $line }
        }

        if ($loadOutput -match 'LOADED: true true true') {
            Write-Ok 'lingofuse_ext loads and exposes the full expected surface.'
        } elseif ($loadOutput -match 'LOADED: true true false') {
            Write-Warn 'lingofuse_ext loads, but test_invoke_from_native_thread is missing.'
            Write-Info 'This is expected if you rebuilt an older lingofuse_ext.c.'
        } else {
            Write-Fail 'Load test did not report the expected surface.'
            Write-Info 'Examine the output above.'
            exit 1
        }
    } finally {
        Remove-Item $loadScript -Force -ErrorAction SilentlyContinue
    }

} finally {
    Pop-Location
}

# =============================================================================
# Report
# =============================================================================

Write-Section 'Done'

Write-Host '  The C extension has been built and installed into lib/.'
Write-Host ''
Write-Host '  Next step:'
Write-Host ''
Write-Host '      ruby test/test_native_bridge_self_test.rb'
Write-Host ''
exit 0