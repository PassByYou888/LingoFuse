<#
.SYNOPSIS
    Check the R extension build environment on Windows.

.DESCRIPTION
    Pure English output. Verifies that the machine has everything
    required to compile a native R extension with "R CMD SHLIB":

      1. R installation (R.exe, Rscript.exe, R_HOME)
      2. R CMD config (the official source of truth for toolchain paths)
      3. C compiler (gcc) and C++ compiler (g++)
      4. R header files (R.h, Rinternals.h)
      5. R.dll (needed for linking on Windows)
      6. Leftover artifacts from previous build attempts

    The script does NOT compile anything. It only reports.

    The final section gives a clear verdict:
        [READY]   the machine can build R extensions
        [BLOCKED] something critical is missing; fix it first

.NOTES
    Run: powershell -ExecutionPolicy Bypass -File .\check_env.ps1
#>

$ErrorActionPreference = "Continue"

$script:PassCount = 0
$script:WarnCount = 0
$script:FailCount = 0

# Collected facts used by the final verdict.
$script:FoundRHome     = $null
$script:FoundRExe      = $null
$script:FoundGcc       = $null
$script:FoundGpp       = $null
$script:FoundRInclude  = $null
$script:FoundRDll      = $null

# -----------------------------------------------------------------------------
# Output helpers
# -----------------------------------------------------------------------------

function Write-Header {
    param([string]$Text)
    Write-Host ""
    Write-Host ("=" * 72) -ForegroundColor Cyan
    Write-Host $Text -ForegroundColor Cyan
    Write-Host ("=" * 72) -ForegroundColor Cyan
}

function Write-Result {
    param(
        [string]$Label,
        [ValidateSet("OK", "WARN", "FAIL")][string]$Status,
        [string]$Detail = ""
    )
    $color = @{ OK = "Green"; WARN = "Yellow"; FAIL = "Red" }[$Status]
    Write-Host ("[{0}] {1}" -f $Status, $Label) -ForegroundColor $color
    if ($Detail) {
        foreach ($line in ($Detail -split "`n")) {
            Write-Host ("       " + $line) -ForegroundColor Gray
        }
    }
    switch ($Status) {
        "OK"   { $script:PassCount++ }
        "WARN" { $script:WarnCount++ }
        "FAIL" { $script:FailCount++ }
    }
}

function Write-Info {
    param([string]$Text)
    Write-Host ("       " + $Text) -ForegroundColor Gray
}

# -----------------------------------------------------------------------------
# Section 1 - R installation
# -----------------------------------------------------------------------------

Write-Header "1. R installation"

$rExe = Get-Command R.exe -ErrorAction SilentlyContinue
if ($rExe) {
    $script:FoundRExe = $rExe.Source
    Write-Result "R.exe found" "OK" $rExe.Source
} else {
    Write-Result "R.exe found" "FAIL" @"
R.exe is not on PATH.
R CMD SHLIB requires the full R.exe, not just Rscript.exe.
Add the R bin directory to PATH. Locate it with:
    Rscript.exe -e "cat(file.path(R.home('bin')))"
or from the R GUI:
    R.home('bin')
"@
}

$rscriptExe = Get-Command Rscript.exe -ErrorAction SilentlyContinue
if ($rscriptExe) {
    Write-Result "Rscript.exe found" "OK" $rscriptExe.Source
} else {
    Write-Result "Rscript.exe found" "WARN" "Not on PATH. Not required for R CMD SHLIB, but useful for tests."
}

if ($script:FoundRExe) {
    # R --version prints to stderr on some builds, so capture both streams.
    $rVersion = (& $script:FoundRExe --version 2>&1 | Select-Object -First 1) -join ""
    Write-Result "R version" "OK" $rVersion.Trim()

    # R_HOME is the authoritative root used to locate headers, DLLs and libs.
    $rHome = (& $script:FoundRExe RHOME 2>&1) -join "`n"
    if ($rHome) {
        $script:FoundRHome = $rHome.Trim()
        Write-Result "R_HOME" "OK" $script:FoundRHome
    } else {
        Write-Result "R_HOME" "FAIL" "R.exe RHOME returned nothing."
    }

    # Architecture is important because the bridge DLL must match it.
    $rArch = (& $script:FoundRExe --arch 2>&1) -join "`n"
    if ($rArch) {
        Write-Result "R architecture" "OK" $rArch.Trim()
    } else {
        Write-Result "R architecture" "WARN" "Could not query (usually harmless)."
    }
}

# -----------------------------------------------------------------------------
# Section 2 - R CMD config
# -----------------------------------------------------------------------------

Write-Header "2. R CMD config (toolchain source of truth)"

if (-not $script:FoundRExe) {
    Write-Result "R CMD config" "FAIL" "Skipped: R.exe not available."
} else {
    # R CMD config is the official way to ask R where its compiler,
    # flags, headers and libraries live. If these commands work, R
    # knows how to build extensions on this machine.

    $cc  = (& $script:FoundRExe CMD config CC  2>&1) -join "`n"
    $cxx = (& $script:FoundRExe CMD config CXX 2>&1) -join "`n"
    $cpp = (& $script:FoundRExe CMD config CPPFLAGS 2>&1) -join "`n"
    $ldf = (& $script:FoundRExe CMD config LDFLAGS  2>&1) -join "`n"

    if ($cc -and $LASTEXITCODE -eq 0) {
        Write-Result "R CMD config CC" "OK" $cc.Trim()
    } else {
        Write-Result "R CMD config CC" "FAIL" "R could not report its C compiler. Rtools is probably missing."
    }

    if ($cxx -and $LASTEXITCODE -eq 0) {
        Write-Result "R CMD config CXX" "OK" $cxx.Trim()
    } else {
        Write-Result "R CMD config CXX" "FAIL" "R could not report its C++ compiler."
    }

    if ($cpp) { Write-Result "R CMD config CPPFLAGS" "OK" $cpp.Trim() }
    else       { Write-Result "R CMD config CPPFLAGS" "WARN" "(empty)" }

    if ($ldf) { Write-Result "R CMD config LDFLAGS" "OK" $ldf.Trim() }
    else       { Write-Result "R CMD config LDFLAGS" "WARN" "(empty)" }
}

# -----------------------------------------------------------------------------
# Section 3 - Compilers
# -----------------------------------------------------------------------------

Write-Header "3. C / C++ compilers used by R CMD SHLIB"

# The compiler that R CMD SHLIB actually invokes is the one R reports
# via "R CMD config CC/CXX". That may be a full path under Rtools, or
# a bare name that the R process resolves through its own PATH. A
# gcc.exe found on the shell's PATH is irrelevant if R does not use it.
if (-not $script:FoundRExe) {
    Write-Result "compiler check" "FAIL" "Skipped: R.exe not available."
} else {
    $ccRaw  = ((& $script:FoundRExe CMD config CC  2>&1) -join "`n").Trim()
    $cxxRaw = ((& $script:FoundRExe CMD config CXX 2>&1) -join "`n").Trim()

    $ccExe  = if ($ccRaw)  { ($ccRaw  -split '\s+')[0] } else { $null }
    $cxxExe = if ($cxxRaw) { ($cxxRaw -split '\s+')[0] } else { $null }

    if ($ccExe) {
        $ccCmd = Get-Command $ccExe -ErrorAction SilentlyContinue
        if ($ccCmd) {
            $script:FoundGcc = $ccCmd.Source
            $ccVersion = (& $ccCmd.Source --version 2>&1 | Select-Object -First 1) -join ""
            Write-Result "C compiler (R CMD config CC)" "OK" `
                ($ccRaw + "`n  resolved: " + $ccCmd.Source + "`n  " + $ccVersion.Trim())
        } else {
            Write-Result "C compiler (R CMD config CC)" "FAIL" `
                ("R reports '" + $ccRaw + "' but '" + $ccExe + "' is not on PATH.")
        }
    } else {
        Write-Result "C compiler (R CMD config CC)" "FAIL" `
            "R CMD config CC returned nothing. Rtools is probably missing."
    }

    if ($cxxExe) {
        $cxxCmd = Get-Command $cxxExe -ErrorAction SilentlyContinue
        if ($cxxCmd) {
            $script:FoundGpp = $cxxCmd.Source
            $cxxVersion = (& $cxxCmd.Source --version 2>&1 | Select-Object -First 1) -join ""
            Write-Result "C++ compiler (R CMD config CXX)" "OK" `
                ($cxxRaw + "`n  resolved: " + $cxxCmd.Source + "`n  " + $cxxVersion.Trim())
        } else {
            Write-Result "C++ compiler (R CMD config CXX)" "FAIL" `
                ("R reports '" + $cxxRaw + "' but '" + $cxxExe + "' is not on PATH.")
        }
    } else {
        Write-Result "C++ compiler (R CMD config CXX)" "FAIL" `
            "R CMD config CXX returned nothing. Rtools is probably missing."
    }
}

# -----------------------------------------------------------------------------
# Section 4 - R headers
# -----------------------------------------------------------------------------

Write-Header "4. R header files"

if (-not $script:FoundRHome) {
    Write-Result "R include directory" "FAIL" "Skipped: R_HOME not known."
} else {
    $rInclude = Join-Path $script:FoundRHome "include"
    if (Test-Path $rInclude) {
        $script:FoundRInclude = $rInclude
        Write-Result "R include directory" "OK" $rInclude
    } else {
        Write-Result "R include directory" "FAIL" "Not found: $rInclude"
    }

    foreach ($hdr in @("R.h", "Rinternals.h", "R_ext\Complex.h", "R_ext\Boolean.h", "R_ext\R_ext.h")) {
        $full = Join-Path $rInclude $hdr
        if (Test-Path $full) {
            Write-Result ("header: " + $hdr) "OK"
        } else {
            Write-Result ("header: " + $hdr) "FAIL" ("Missing: " + $full)
        }
    }
}

# -----------------------------------------------------------------------------
# Section 5 - R.dll
# -----------------------------------------------------------------------------

Write-Header "5. R.dll"

if (-not $script:FoundRHome) {
    Write-Result "R.dll" "FAIL" "Skipped: R_HOME not known."
} else {
    # On Windows, R.dll lives under bin\x64 (64-bit) or bin\i386
    # (32-bit). The linker needs it to resolve R API symbols.
    $candidates = @(
        (Join-Path $script:FoundRHome "bin\x64\R.dll"),
        (Join-Path $script:FoundRHome "bin\i386\R.dll"),
        (Join-Path $script:FoundRHome "bin\R.dll")
    )
    $found = $null
    foreach ($c in $candidates) {
        if (Test-Path $c) { $found = $c; break }
    }
    if ($found) {
        $script:FoundRDll = $found
        Write-Result "R.dll found" "OK" $found
    } else {
        Write-Result "R.dll found" "FAIL" ("Not found under " + $script:FoundRHome + "\bin")
    }
}

# -----------------------------------------------------------------------------
# Section 6 - Existing build artifacts
# -----------------------------------------------------------------------------

Write-Header "6. Existing build artifacts in the repository"

$repoRoot = $PSScriptRoot
Write-Info ("Repository root: " + $repoRoot)

$toCheck = @(
    @{ Path = (Join-Path $repoRoot "c_ext\build");                       Desc = "CMake build tree (from the earlier attempt)" },
    @{ Path = (Join-Path $repoRoot "c_ext\CMakeLists.txt");              Desc = "CMake project file (no longer used)" },
    @{ Path = (Join-Path $repoRoot "libs");                              Desc = "Output directory" },
    @{ Path = (Join-Path $repoRoot "c_ext\src\lf_r_shim.c");             Desc = "Source: lf_r_shim.c" },
    @{ Path = (Join-Path $repoRoot "c_ext\src\lf_r_shim.h");             Desc = "Source: lf_r_shim.h" },
    @{ Path = (Join-Path $repoRoot "c_ext\src\lf_bridge.cpp");           Desc = "Source: lf_bridge.cpp" },
    @{ Path = (Join-Path $repoRoot "c_ext\tests\smoke_test.R");          Desc = "Test: smoke_test.R" }
)

foreach ($item in $toCheck) {
    if (Test-Path $item.Path) {
        Write-Info ("[present] " + $item.Desc)
    } else {
        Write-Info ("[absent ] " + $item.Desc)
    }
}

# Look for stray object files left by a previous in-source build.
$srcDir = Join-Path $repoRoot "c_ext\src"
if (Test-Path $srcDir) {
    $stray = Get-ChildItem -Path $srcDir -Include "*.o", "*.obj" -File -ErrorAction SilentlyContinue
    if ($stray -and $stray.Count -gt 0) {
        Write-Info ("[present] " + $stray.Count + " stray object file(s) in c_ext\src")
    } else {
        Write-Info "[absent ] stray object files in c_ext\src"
    }
}

# -----------------------------------------------------------------------------
# Verdict
# -----------------------------------------------------------------------------

Write-Header "Verdict"

$blockers = @()
if (-not $script:FoundRExe)     { $blockers += "R.exe not on PATH" }
if (-not $script:FoundRHome)    { $blockers += "R_HOME not determined" }
if (-not $script:FoundGcc)      { $blockers += "gcc not on PATH" }
if (-not $script:FoundGpp)      { $blockers += "g++ not on PATH" }
if (-not $script:FoundRInclude) { $blockers += "R include directory not found" }
if (-not $script:FoundRDll)     { $blockers += "R.dll not found" }

if ($blockers.Count -eq 0) {
    Write-Host "[READY] The environment can build R extensions." -ForegroundColor Green
    Write-Host ""
    Write-Host "  R_HOME       : " -NoNewline; Write-Host $script:FoundRHome
    Write-Host "  R.exe        : " -NoNewline; Write-Host $script:FoundRExe
    Write-Host "  gcc          : " -NoNewline; Write-Host $script:FoundGcc
    Write-Host "  g++          : " -NoNewline; Write-Host $script:FoundGpp
    Write-Host "  include dir  : " -NoNewline; Write-Host $script:FoundRInclude
    Write-Host "  R.dll        : " -NoNewline; Write-Host $script:FoundRDll
    exit 0
} else {
    Write-Host "[BLOCKED] The environment cannot build R extensions yet." -ForegroundColor Red
    Write-Host ""
    Write-Host "  Missing:" -ForegroundColor Red
    foreach ($b in $blockers) {
        Write-Host ("    - " + $b) -ForegroundColor Red
    }
    Write-Host ""
    Write-Host "  Typical fix:" -ForegroundColor Yellow
    Write-Host "    1. Install Rtools from https://cran.r-project.org/bin/windows/Rtools/"
    Write-Host "       Choose the version that matches your R version."
    Write-Host "    2. During setup, tick 'Add rtools to system PATH'."
    Write-Host "    3. Restart PowerShell so the new PATH is picked up."
    Write-Host "    4. Re-run this script."
    exit 1
}