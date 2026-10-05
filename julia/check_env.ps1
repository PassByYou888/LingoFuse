<#
.SYNOPSIS
    Comprehensive environment check for the LingoFuse Julia binding
    development environment.

.DESCRIPTION
    Validates the system, Julia installation, VS Code setup, C toolchain,
    LingoFuse project layout, runtime libraries, and build artifacts.
    Produces an actionable summary at the end.

    The runtime library (LingoFuse64.dll) is resolved through the same
    mechanism the OS dynamic loader uses: PATH on Windows, and an
    explicit LINGOFUSE_LIBRARY override takes precedence over the
    search path. No hard-coded directories are consulted.

.NOTES
    Run this script from a PowerShell terminal. No admin privileges are
    required for the checks themselves.
#>

# --- Helper Function for Styled Output ---
function Write-Status {
    param (
        [Parameter(Mandatory=$true)]
        [ValidateSet("INFO", "PASS", "WARN", "FAIL")]
        [string]$Status,

        [Parameter(Mandatory=$true)]
        [string]$Message
    )

    $color = "White"
    switch ($Status) {
        "INFO" { $color = "Cyan"   }
        "PASS" { $color = "Green"  }
        "WARN" { $color = "Yellow" }
        "FAIL" { $color = "Red"    }
    }

    Write-Host "[$Status] " -ForegroundColor $color -NoNewline
    Write-Host $Message
}

# --- Path setup ---
$scriptDir = $PSScriptRoot
if (-not $scriptDir) { $scriptDir = (Get-Location).Path }
$cExtDir   = Join-Path $scriptDir "c_ext"
$repoRoot  = Split-Path -Parent $scriptDir

# --- Header ---
Clear-Host
Write-Host "=====================================================================" -ForegroundColor Magenta
Write-Host "   LINGOFUSE JULIA BINDING - ENVIRONMENT DIAGNOSTIC TOOL             " -ForegroundColor Magenta
Write-Host "=====================================================================" -ForegroundColor Magenta
Write-Host ""

# =====================================================================
# 1. System Environment
# =====================================================================
Write-Host "--- 1. System Environment ---" -ForegroundColor White
$os = Get-CimInstance Win32_OperatingSystem
Write-Status "INFO" "OS: $($os.Caption)"
Write-Status "INFO" "Version: $($os.Version)"
Write-Status "INFO" "PowerShell Version: $($PSVersionTable.PSVersion.ToString())"
Write-Status "INFO" "Architecture: $($env:PROCESSOR_ARCHITECTURE)"

$executionPolicy = Get-ExecutionPolicy
if ($executionPolicy -eq "Restricted") {
    Write-Status "WARN" "PowerShell ExecutionPolicy is 'Restricted'. You might not be able to run scripts."
    Write-Status "INFO" "Fix: Set-ExecutionPolicy -Scope CurrentUser -ExecutionPolicy RemoteSigned"
} else {
    Write-Status "PASS" "PowerShell ExecutionPolicy is '$executionPolicy'."
}
Write-Host ""

# =====================================================================
# 2. Julia Installation
# =====================================================================
Write-Host "--- 2. Julia Installation ---" -ForegroundColor White
$juliaCmd  = Get-Command "julia" -ErrorAction SilentlyContinue
$juliaPath = ""

if ($juliaCmd) {
    $juliaPath = $juliaCmd.Source
    Write-Status "PASS" "Julia is globally available in PATH: $juliaPath"
} else {
    Write-Status "WARN" "Julia is NOT in the system PATH."

    # Fallback: check the expected user-specific installation path.
    $expectedPath = "$env:LOCALAPPDATA\Programs\Julia-1.13.1\bin\julia.exe"
    if (Test-Path $expectedPath) {
        $juliaPath = $expectedPath
        Write-Status "INFO" "Found Julia at expected installation path: $juliaPath"
    } else {
        Write-Status "FAIL" "Julia executable not found in PATH or expected location ($expectedPath)."
    }
}

if ($juliaPath) {
    try {
        $juliaVersion = & $juliaPath --version 2>&1
        Write-Status "PASS" "Successfully executed Julia. Version: $juliaVersion"

        # Minimum version check.
        $verString = ($juliaVersion -replace '^julia version\s+','').Trim()
        try {
            $ver = [version]$verString
            if ($ver -lt [version]"1.9.0") {
                Write-Status "WARN" "Julia $verString is older than 1.9.0. Upgrade to 1.10+ recommended."
            } else {
                Write-Status "PASS" "Julia version $verString satisfies the minimum requirement (>= 1.9)."
            }
        } catch {
            Write-Status "INFO" "Could not parse Julia version string: $verString"
        }

        # Depot path
        $juliaDepot = & $juliaPath -e "println(DEPOT_PATH[1])" 2>&1
        Write-Status "INFO" "Default Julia Depot Path: $juliaDepot"

        # Thread support: the C-shim test requires at least 2 threads
        # when the consumer loop runs on a separate Julia thread.
        $threadCount = & $juliaPath --threads=2 -e "println(Threads.nthreads())" 2>&1
        if ($threadCount -eq "2") {
            Write-Status "PASS" "Julia multi-threading support verified (--threads=2)."
        } else {
            Write-Status "WARN" "Julia did not report 2 threads when invoked with --threads=2 (got: $threadCount)."
        }

        # Libdl stdlib availability.
        #
        # The check is written via a here-string so PowerShell does not
        # mangle the quoting of the Julia source. A distinct sentinel
        # token ("LIBDL_OK") is printed and matched, and the process
        # exit code is also checked, so a Julia-side syntax error or a
        # startup warning cannot be mistaken for success.
        #
        # NOTE: this check exists primarily to catch a broken Julia
        # installation. Libdl is a standard library and should always
        # be available.
        $libdlCode = @'
using Libdl
if isdefined(Libdl, :dlopen)
    println("LIBDL_OK")
else
    println("LIBDL_MISSING")
    exit(2)
end
'@
        $libdlOut  = & $juliaPath -e $libdlCode 2>&1
        $libdlExit = $LASTEXITCODE
        $libdlText = ($libdlOut | Out-String).Trim()

        if ($libdlExit -eq 0 -and $libdlText -match "LIBDL_OK") {
            Write-Status "PASS" "Julia stdlib Libdl is available (dlopen present)."
        } else {
            Write-Status "FAIL" "Julia Libdl stdlib check failed. Exit code: $libdlExit"
            if ($libdlText) {
                Write-Status "INFO" "Julia output:"
                $libdlText -split "`r?`n" | ForEach-Object {
                    if ($_ -ne "") { Write-Status "INFO" "    $_" }
                }
            }
        }
    } catch {
        Write-Status "FAIL" "Found Julia executable, but failed to run it. Error: $_"
    }
}
Write-Host ""

# =====================================================================
# 3. VS Code Installation & Extensions
# =====================================================================
Write-Host "--- 3. VS Code Installation & Extensions ---" -ForegroundColor White
$codeCmd = Get-Command "code" -ErrorAction SilentlyContinue
if ($codeCmd) {
    Write-Status "PASS" "VS Code CLI ('code') is available."

    $extensions = code --list-extensions 2>$null
    if ($extensions -match "julialang.language-julia") {
        Write-Status "PASS" "Julia extension (julialang.language-julia) is installed."

        $extVersion = (code --list-extensions --show-versions 2>$null |
                       Select-String "julialang.language-julia").ToString()
        Write-Status "INFO" "Extension details: $extVersion"
    } else {
        Write-Status "FAIL" "Julia extension (julialang.language-julia) is NOT installed."
        Write-Status "INFO" "Fix: code --install-extension julialang.language-julia"
    }
} else {
    Write-Status "WARN" "VS Code CLI ('code') is not found in PATH. Skipping VS Code extension checks."
    Write-Status "INFO" "Note: You can still use VS Code, but command-line checks are unavailable."
}
Write-Host ""

# =====================================================================
# 4. VS Code Settings (settings.json)
# =====================================================================
Write-Host "--- 4. VS Code Settings (settings.json) ---" -ForegroundColor White
$settingsPath = "$env:APPDATA\Code\User\settings.json"

if (Test-Path $settingsPath) {
    Write-Status "PASS" "Found VS Code settings.json at: $settingsPath"
    try {
        $settingsRaw = Get-Content $settingsPath -Raw
        $settings = $settingsRaw | ConvertFrom-Json

        $configuredJuliaPath = $settings.'julia.executablePath'

        if ($configuredJuliaPath) {
            Write-Status "INFO" "julia.executablePath is set to: $configuredJuliaPath"

            if (Test-Path $configuredJuliaPath -PathType Leaf) {
                if ($configuredJuliaPath -match "julia\.exe$") {
                    Write-Status "PASS" "Configured path looks correct and points to an executable."
                } else {
                    Write-Status "WARN" "Configured path exists but does not end with 'julia.exe'."
                }
            } elseif (Test-Path $configuredJuliaPath -PathType Container) {
                Write-Status "FAIL" "Configured path is a DIRECTORY, not an executable. Append '\bin\julia.exe'."
            } else {
                Write-Status "FAIL" "Configured path does not exist on the file system."
            }
        } else {
            Write-Status "WARN" "julia.executablePath is not set. The extension will auto-detect Julia."
        }
    } catch {
        Write-Status "FAIL" "Failed to parse settings.json. Ensure it is valid JSON. Error: $_"
    }
} else {
    Write-Status "INFO" "VS Code settings.json not found at standard location."
}
Write-Host ""

# =====================================================================
# 5. C Toolchain (required to build c_ext)
# =====================================================================
Write-Host "--- 5. C Toolchain (for c_ext build) ---" -ForegroundColor White

$gccCmd   = Get-Command "gcc"   -ErrorAction SilentlyContinue
$clangCmd = Get-Command "clang" -ErrorAction SilentlyContinue
$ccCmd    = Get-Command "cc"    -ErrorAction SilentlyContinue
$clCmd    = Get-Command "cl"    -ErrorAction SilentlyContinue

$cCompiler = $null
$cCompilerName = ""

if ($gccCmd) {
    $cCompiler = $gccCmd.Source
    $cCompilerName = "gcc (MinGW-w64 / MSYS2)"
} elseif ($clangCmd) {
    $cCompiler = $clangCmd.Source
    $cCompilerName = "clang"
} elseif ($ccCmd) {
    $cCompiler = $ccCmd.Source
    $cCompilerName = "cc"
} elseif ($clCmd) {
    Write-Status "WARN" "Only MSVC 'cl.exe' found at $($clCmd.Source)."
    Write-Status "INFO" "build.ps1 requires MinGW-w64 gcc. Install MinGW-w64 or MSYS2."
}

if ($cCompiler) {
    Write-Status "PASS" "C compiler found: $cCompilerName"
    Write-Status "INFO" "Path: $cCompiler"

    try {
        $ccVersion = & $cCompiler --version 2>&1 | Select-Object -First 1
        Write-Status "INFO" "Version: $ccVersion"

        if ($cCompilerName -like "gcc*") {
            # Verify 64-bit target architecture. The Julia binding is
            # built for x86_64, so a 32-bit gcc would produce an
            # unloadable DLL.
            $target = & $cCompiler -dumpmachine 2>&1
            if ($target -match "x86_64|amd64") {
                Write-Status "PASS" "gcc target architecture: $target (x86_64)"
            } else {
                Write-Status "WARN" "gcc target is '$target', not x86_64. DLL may not load into 64-bit Julia."
            }
        }
    } catch {
        Write-Status "WARN" "Could not query compiler version: $_"
    }
} elseif (-not $clCmd) {
    Write-Status "FAIL" "No C compiler found. The c_ext module cannot be built."
    Write-Status "INFO" "Install MinGW-w64 (winget install --id=BrechtSanders.WinLibs.POSIX.UCRT) or MSYS2."
}
Write-Host ""

# =====================================================================
# 6. LingoFuse Project Layout
# =====================================================================
Write-Host "--- 6. LingoFuse Project Layout ---" -ForegroundColor White

Write-Status "INFO" "Script directory : $scriptDir"
Write-Status "INFO" "Repo root        : $repoRoot"

# --- c_ext directory and files ---
if (Test-Path $cExtDir -PathType Container) {
    Write-Status "PASS" "c_ext directory found: $cExtDir"

    $requiredFiles = @(
        "lf_shim.h",
        "lf_shim.c",
        "mock_lf.h",
        "mock_lf.c",
        "build.ps1",
        "build.sh",
        "test_shim.jl"
    )

    $missing = @()
    foreach ($f in $requiredFiles) {
        $p = Join-Path $cExtDir $f
        if (-not (Test-Path $p -PathType Leaf)) {
            $missing += $f
        }
    }

    if ($missing.Count -eq 0) {
        Write-Status "PASS" "All 7 required c_ext source files are present."
    } else {
        Write-Status "FAIL" "Missing c_ext files: $($missing -join ', ')"
    }
} else {
    Write-Status "FAIL" "c_ext directory NOT found at: $cExtDir"
    Write-Status "INFO" "Expected layout: <julia>/check_env.ps1 + <julia>/c_ext/..."
}
Write-Host ""

# =====================================================================
# 7. LingoFuse Runtime Library
# =====================================================================
Write-Host "--- 7. LingoFuse Runtime Library ---" -ForegroundColor White

# Resolution strategy
# ------------------
# The Julia binding resolves the runtime through the same mechanism
# the OS dynamic loader uses. On Windows that is PATH. An explicit
# LINGOFUSE_LIBRARY override takes precedence over the search path
# and is checked first. No hard-coded directories are consulted.

$override        = $env:LINGOFUSE_LIBRARY
$runtimeFullPath = $null

if ($override -and $override.Length -gt 0) {
    if (Test-Path $override -PathType Leaf) {
        $runtimeFullPath = $override
        Write-Status "PASS" "LINGOFUSE_LIBRARY override is set and valid."
        Write-Status "INFO" "    $runtimeFullPath"
    } else {
        Write-Status "FAIL" "LINGOFUSE_LIBRARY is set but does not name an existing file."
        Write-Status "INFO" "    $override"
    }
} else {
    $libNames    = @("LingoFuse64.dll", "LingoFuse32.dll")
    $pathEntries = ($env:PATH -split ';') | Where-Object { $_ -ne '' }
    foreach ($dir in $pathEntries) {
        foreach ($lib in $libNames) {
            $cand = Join-Path $dir $lib
            if (Test-Path $cand -PathType Leaf) {
                $runtimeFullPath = $cand
                break
            }
        }
        if ($runtimeFullPath) { break }
    }
    if ($runtimeFullPath) {
        Write-Status "PASS" "LingoFuse runtime found on PATH."
        Write-Status "INFO" "    $runtimeFullPath"
    } else {
        Write-Status "FAIL" "LingoFuse runtime not found on PATH and LINGOFUSE_LIBRARY is not set."
        Write-Status "INFO" "Add the directory that contains LingoFuse64.dll to PATH, or"
        Write-Status "INFO" "set LINGOFUSE_LIBRARY to the full DLL path."
    }
}

if ($runtimeFullPath) {
    $runtimeDir = Split-Path -Parent $runtimeFullPath

    $mainName = Split-Path -Leaf $runtimeFullPath
    $mainSize = (Get-Item $runtimeFullPath).Length
    Write-Status "PASS" "$mainName  ($([math]::Round($mainSize/1KB,1)) KB)"

    # Dependencies expected next to the runtime library.
    $ipcName = "z_ipc_64.dll"
    $mmName  = "mimalloc64.dll"
    $ipcFull = Join-Path $runtimeDir $ipcName
    $mmFull  = Join-Path $runtimeDir $mmName

    if (Test-Path $ipcFull -PathType Leaf) {
        $size = (Get-Item $ipcFull).Length
        Write-Status "PASS" "$ipcName  ($([math]::Round($size/1KB,1)) KB)  [required dependency]"
    } else {
        Write-Status "FAIL" "$ipcName NOT found next to $mainName. LingoFuse64.dll will fail to load."
    }

    if (Test-Path $mmFull -PathType Leaf) {
        $size = (Get-Item $mmFull).Length
        Write-Status "PASS" "$mmName  ($([math]::Round($size/1KB,1)) KB)  [optional allocator]"
    } else {
        Write-Status "WARN" "$mmName not found (optional; LingoFuse falls back to the system allocator)."
    }

    # Whether the runtime directory is reachable by the dynamic loader.
    $pathEntries = ($env:PATH -split ';') | Where-Object { $_ -ne '' }
    if ($pathEntries -contains $runtimeDir) {
        Write-Status "PASS" "The runtime directory is on PATH."
    } else {
        Write-Status "INFO" "The runtime directory is not directly on PATH, but the"
        Write-Status "INFO" "resolution above shows the runtime is discoverable."
    }
} else {
    Write-Status "INFO" "This check is OK for c_ext development (mock_lf.c substitutes the real library)."
    Write-Status "INFO" "It becomes REQUIRED when running the acceptance tests against the real runtime."
}
Write-Host ""

# =====================================================================
# 8. C Extension Build Artifacts
# =====================================================================
Write-Host "--- 8. C Extension Build Artifacts ---" -ForegroundColor White

if (Test-Path $cExtDir -PathType Container) {
    $mockShim = Join-Path $cExtDir "lf_shim_mock.dll"
    $realShim = Join-Path $cExtDir "real\lf_shim_real.dll"

    if (Test-Path $mockShim -PathType Leaf) {
        $info = Get-Item $mockShim
        Write-Status "PASS" "Mock shim found: lf_shim_mock.dll"
        Write-Status "INFO" "  Size    : $([math]::Round($info.Length/1KB,1)) KB"
        Write-Status "INFO" "  Built at: $($info.LastWriteTime)"
    } else {
        Write-Status "INFO" "Mock shim not built: $mockShim"
    }

    if (Test-Path $realShim -PathType Leaf) {
        $info = Get-Item $realShim
        Write-Status "PASS" "Real shim found: lf_shim_real.dll"
        Write-Status "INFO" "  Size    : $([math]::Round($info.Length/1KB,1)) KB"
        Write-Status "INFO" "  Built at: $($info.LastWriteTime)"
        if (-not $runtimeFullPath) {
            Write-Status "WARN" "Real shim is present but the LingoFuse runtime was not located."
            Write-Status "INFO" "Runtime usage will fail until the runtime is discoverable."
        }
    } else {
        Write-Status "INFO" "Real shim not built: $realShim"
        Write-Status "INFO" "Build it with: cd `"$cExtDir\real`"; .\build.ps1"
    }
} else {
    Write-Status "INFO" "Skipped (c_ext directory not found)."
}
Write-Host ""

# =====================================================================
# 9. Final Summary
# =====================================================================
Write-Host "=====================================================================" -ForegroundColor Magenta
Write-Host "                         DIAGNOSTIC COMPLETE                         " -ForegroundColor Magenta
Write-Host "=====================================================================" -ForegroundColor White
Write-Host ""

Write-Host "Next steps for the LingoFuse Julia binding:" -ForegroundColor White
Write-Host ""

Write-Host "  [Step 1]  Build the C shims" -ForegroundColor Gray
Write-Host "            cd `"$cExtDir`"" -ForegroundColor DarkGray
Write-Host "            .\build.ps1" -ForegroundColor DarkGray
Write-Host "            cd `"$cExtDir\real`"" -ForegroundColor DarkGray
Write-Host "            .\build.ps1" -ForegroundColor DarkGray
Write-Host ""

Write-Host "  [Step 1]  Run the mock shim test (REQUIRES 2+ JULIA THREADS)" -ForegroundColor Gray
Write-Host "            julia --threads=2 test_shim.jl" -ForegroundColor DarkGray
Write-Host ""

Write-Host "  [Step 2]  Wire the 33 non-callback LF_* exports to the real" -ForegroundColor Gray
Write-Host "            LingoFuse runtime. Requires section 7 to be PASS." -ForegroundColor Gray
Write-Host ""

Write-Host "  [Step 3]  Add the high-level JSON / string wrapper layer." -ForegroundColor Gray
Write-Host ""

Write-Host "  [Step 4]  Port the Cross demo (CrossService / CrossNode / CrossCall)." -ForegroundColor Gray
Write-Host ""

if ($executionPolicy -eq "Restricted") {
    Write-Host "Troubleshooting:" -ForegroundColor Yellow
    Write-Host "  - Set-ExecutionPolicy -Scope CurrentUser -ExecutionPolicy RemoteSigned" -ForegroundColor Gray
    Write-Host ""
}

Write-Host "  The LingoFuse runtime is resolved through the same search path" -ForegroundColor Gray
Write-Host "  the OS dynamic loader uses. Make the directory that contains" -ForegroundColor Gray
Write-Host "  LingoFuse64.dll reachable in one of these ways:" -ForegroundColor Gray
Write-Host "    * Append the directory to PATH." -ForegroundColor DarkGray
Write-Host "    * Set `$env:LINGOFUSE_LIBRARY to the full DLL path." -ForegroundColor DarkGray
Write-Host ""
Write-Host "  Restart VS Code after changing settings.json or PATH." -ForegroundColor Gray
Write-Host ""