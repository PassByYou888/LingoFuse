# ============================================================
#  LingoFuse Dart FFI Environment Check
#  Save as check-env.ps1 and run in PowerShell:
#      .\check-env.ps1
#  If blocked by execution policy, use:
#      powershell -ExecutionPolicy Bypass -File .\check-env.ps1
# ============================================================

$ErrorActionPreference = 'SilentlyContinue'

function Write-Header($text) {
    Write-Host ""
    Write-Host ("=" * 66) -ForegroundColor Cyan
    Write-Host "  $text" -ForegroundColor Cyan
    Write-Host ("=" * 66) -ForegroundColor Cyan
}

function Write-Ok($text)   { Write-Host "  [OK]   $text" -ForegroundColor Green }
function Write-Fail($text) { Write-Host "  [FAIL] $text" -ForegroundColor Red }
function Write-Warn($text) { Write-Host "  [WARN] $text" -ForegroundColor Yellow }
function Write-Info($text) { Write-Host "         $text" -ForegroundColor Gray }

# ------------------------------------------------------------
# 0. System information
# ------------------------------------------------------------
Write-Header "0. System Information"

Write-Info "OS:         $((Get-CimInstance Win32_OperatingSystem).Caption)"
Write-Info "Version:    $([System.Environment]::OSVersion.Version)"
Write-Info "Arch:       $env:PROCESSOR_ARCHITECTURE"
Write-Info "PS version: $($PSVersionTable.PSVersion)"
Write-Info "User:       $env:USERNAME"
Write-Info "CWD:        $(Get-Location)"

# ------------------------------------------------------------
# 1. Dart SDK
# ------------------------------------------------------------
Write-Header "1. Dart SDK"

$dartCmd = Get-Command dart -ErrorAction SilentlyContinue
if ($dartCmd) {
    Write-Ok "dart command available: $($dartCmd.Source)"
    try {
        $ver = & dart --version 2>&1
        Write-Info "$ver"
    } catch {
        Write-Warn "dart --version failed"
    }
} else {
    Write-Fail "dart command not found (not in PATH)"

    $candidates = @(
        "C:\tools\dart-sdk\bin\dart.exe",
        "C:\dart-sdk\bin\dart.exe",
        "$env:LOCALAPPDATA\dart-sdk\bin\dart.exe",
        "$env:USERPROFILE\dart-sdk\bin\dart.exe",
        "C:\src\flutter\bin\dart.exe"
    )
    foreach ($c in $candidates) {
        if (Test-Path $c) {
            Write-Warn "found outside PATH: $c"
        }
    }
}

$flutterCmd = Get-Command flutter -ErrorAction SilentlyContinue
if ($flutterCmd) {
    Write-Ok "flutter command available: $($flutterCmd.Source)"
} else {
    Write-Info "flutter not installed (optional)"
}

# ------------------------------------------------------------
# 2. VSCode
# ------------------------------------------------------------
Write-Header "2. VSCode"

$codeCmd = Get-Command code -ErrorAction SilentlyContinue
if ($codeCmd) {
    Write-Ok "code command available: $($codeCmd.Source)"
    try {
        $ver = & code --version 2>&1 | Select-Object -First 1
        Write-Info "VSCode version: $ver"
    } catch {}
} else {
    $vscodePaths = @(
        "$env:LOCALAPPDATA\Programs\Microsoft VS Code\Code.exe",
        "$env:ProgramFiles\Microsoft VS Code\Code.exe",
        "${env:ProgramFiles(x86)}\Microsoft VS Code\Code.exe"
    )
    $found = $false
    foreach ($p in $vscodePaths) {
        if (Test-Path $p) {
            Write-Ok "VSCode installed but not in PATH: $p"
            $found = $true
            break
        }
    }
    if (-not $found) {
        Write-Fail "VSCode not found"
    }
}

$dartExtPath = "$env:USERPROFILE\.vscode\extensions"
if (Test-Path $dartExtPath) {
    $dartExt = Get-ChildItem $dartExtPath -Directory | Where-Object { $_.Name -like "dart-code.dart-code-*" }
    if ($dartExt) {
        Write-Ok "Dart extension installed: $($dartExt.Name)"
    } else {
        Write-Warn "Dart extension (dart-code.dart-code) not found in ~/.vscode/extensions"
    }
} else {
    Write-Info "~/.vscode/extensions does not exist (VSCode may not have run yet)"
}

# ------------------------------------------------------------
# 3. Visual Studio 2022 + C++ workload
# ------------------------------------------------------------
Write-Header "3. Visual Studio 2022"

$vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
if (Test-Path $vswhere) {
    Write-Ok "vswhere present"

    $vsInstall = & $vswhere -latest -products * -property installationPath 2>$null
    if ($vsInstall) {
        Write-Info "VS install path: $vsInstall"

        $vcTools = & $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath 2>$null
        if ($vcTools) {
            Write-Ok "C++ desktop workload installed (MSVC v143)"
        } else {
            Write-Fail "Missing 'Desktop development with C++' workload"
        }

        $cmakeComponent = & $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.CMake.Project -property installationPath 2>$null
        if ($cmakeComponent) {
            Write-Ok "VS built-in CMake component installed"
        } else {
            Write-Warn "VS 'C++ CMake tools' component not installed"
        }
    } else {
        Write-Fail "vswhere present but no VS installation found"
    }
} else {
    Write-Fail "vswhere not found - VS2022 may not be installed"
}

Write-Host ""
$vcvarsCandidates = Get-ChildItem "${env:ProgramFiles}\Microsoft Visual Studio\2022" -Directory -ErrorAction SilentlyContinue
if ($vcvarsCandidates) {
    foreach ($ed in $vcvarsCandidates) {
        $vcvars = Join-Path $ed.FullName "VC\Auxiliary\Build\vcvars64.bat"
        if (Test-Path $vcvars) {
            Write-Ok "found vcvars64.bat: $vcvars"
        }
    }
}

# ------------------------------------------------------------
# 4. LLVM / clang
# ------------------------------------------------------------
Write-Header "4. LLVM / clang"

$clangCmd = Get-Command clang -ErrorAction SilentlyContinue
if ($clangCmd) {
    Write-Ok "clang command available: $($clangCmd.Source)"
    try {
        $ver = & clang --version 2>&1 | Select-Object -First 1
        Write-Info "clang version: $ver"
    } catch {}
} else {
    Write-Fail "clang command not found"
}

$libclangCandidates = @(
    "C:\Program Files\LLVM\bin\libclang.dll",
    "C:\Program Files (x86)\LLVM\bin\libclang.dll",
    "C:\LLVM\bin\libclang.dll"
)
$libclangFound = $false
foreach ($c in $libclangCandidates) {
    if (Test-Path $c) {
        Write-Ok "found libclang.dll: $c"
        $libclangFound = $true
        break
    }
}
if (-not $libclangFound) {
    Write-Fail "libclang.dll not found in common locations (required by ffigen)"
}

# ------------------------------------------------------------
# 5. CMake
# ------------------------------------------------------------
Write-Header "5. CMake"

$cmakeCmd = Get-Command cmake -ErrorAction SilentlyContinue
if ($cmakeCmd) {
    Write-Ok "cmake command available: $($cmakeCmd.Source)"
    try {
        $ver = & cmake --version 2>&1 | Select-Object -First 1
        Write-Info "$ver"
    } catch {}
} else {
    Write-Fail "cmake command not found"

    $vsCmake = "C:\Program Files\Microsoft Visual Studio\2022\Community\Common7\IDE\CommonExtensions\Microsoft\CMake\CMake\bin\cmake.exe"
    if (Test-Path $vsCmake) {
        Write-Warn "VS built-in CMake present but not in PATH: $vsCmake"
    }
}

# ------------------------------------------------------------
# 6. Git (optional)
# ------------------------------------------------------------
Write-Header "6. Git"

$gitCmd = Get-Command git -ErrorAction SilentlyContinue
if ($gitCmd) {
    Write-Ok "git command available: $($gitCmd.Source)"
    try {
        $ver = & git --version 2>&1
        Write-Info "$ver"
    } catch {}
} else {
    Write-Warn "git not installed (optional)"
}

# ------------------------------------------------------------
# 7. LingoFuse native library (.dll)
# ------------------------------------------------------------
Write-Header "7. LingoFuse native library (.dll)"

$lfDllNames = @("LingoFuse64.dll", "LingoFuse32.dll")
$searchPaths = @(
    (Get-Location).Path,
    "D:\CoreLibrary\LingoFuse\Binary",
    "D:\CoreLibrary\LingoFuse\dart\native",
    "$env:USERPROFILE\Desktop",
    "$env:USERPROFILE\Downloads"
)

$foundAnyDll = $false
foreach ($sp in $searchPaths) {
    foreach ($dll in $lfDllNames) {
        $full = Join-Path $sp $dll
        if (Test-Path $full) {
            Write-Ok "found $dll : $full"
            $foundAnyDll = $true
        }
    }
}

Get-ChildItem -Path . -Filter "LingoFuse*.dll" -Recurse -Depth 2 -ErrorAction SilentlyContinue | ForEach-Object {
    Write-Ok "found in current tree: $($_.FullName)"
    $foundAnyDll = $true
}

if (-not $foundAnyDll) {
    Write-Warn "LingoFuse64.dll not found in common locations"
    Write-Info "Expected at D:\CoreLibrary\LingoFuse\Binary\LingoFuse64.dll"
}

$depDlls = @("z_ipc_64.dll", "mimalloc64.dll")
foreach ($dll in $depDlls) {
    $found = $false
    foreach ($sp in $searchPaths) {
        $full = Join-Path $sp $dll
        if (Test-Path $full) {
            Write-Ok "found dependency $dll : $full"
            $found = $true
            break
        }
    }
    if (-not $found) {
        Write-Warn "dependency $dll not found (may ship with LingoFuse)"
    }
}

# ------------------------------------------------------------
# 8. PATH environment key entries
# ------------------------------------------------------------
Write-Header "8. PATH key entries"

$pathParts = $env:PATH -split ';'
$keywords = @('dart', 'llvm', 'cmake', 'flutter', 'VS Code', 'LingoFuse')
foreach ($k in $keywords) {
    $match = $pathParts | Where-Object { $_ -match $k }
    if ($match) {
        foreach ($m in $match) { Write-Ok "$k -> $m" }
    } else {
        Write-Info "$k not in PATH"
    }
}

# ------------------------------------------------------------
# Summary
# ------------------------------------------------------------
Write-Header "Summary"

$missing = @()
if (-not $dartCmd)      { $missing += "Dart SDK" }
if (-not $codeCmd -and -not (Test-Path "$env:LOCALAPPDATA\Programs\Microsoft VS Code\Code.exe")) { $missing += "VSCode" }
if (-not (Test-Path $vswhere)) { $missing += "Visual Studio 2022" }
if (-not $clangCmd)     { $missing += "LLVM/clang" }
if (-not $cmakeCmd)     { $missing += "CMake" }

if ($missing.Count -eq 0) {
    Write-Ok "All required components are ready. You can start Dart FFI development."
} else {
    Write-Warn "The following components are missing or not in PATH:"
    foreach ($m in $missing) {
        Write-Host "         - $m" -ForegroundColor Yellow
    }
    Write-Host ""
    Write-Info "Paste the full output above and the assistant will advise."
}

Write-Host ""