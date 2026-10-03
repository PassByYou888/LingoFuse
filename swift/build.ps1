# =============================================================================
#  build.ps1
# -----------------------------------------------------------------------------
#  One-shot build driver for the LingoFuse Swift binding.
#
#  Steps:
#    1. Locate the project root (the directory that contains this script).
#    2. Verify that the Swift toolchain is installed and reachable.
#    3. Print the environment (Swift version, platform, architecture).
#    4. Locate the LingoFuse native library in the common candidate paths.
#    5. Run `swift build` in the requested configuration.
#    6. Optionally copy the native library next to the built executables.
#
#  Usage:
#      .\build.ps1
#      .\build.ps1 -Release
#      .\build.ps1 -CopyNative
#      .\build.ps1 -Release -CopyNative -Quiet
#
#  Exit codes:
#      0  build succeeded
#      1  build failed
#      2  startup error (Swift not found, Package.swift missing, ...)
#
#  Windows execution policy:
#      If PowerShell refuses to run this script, start the shell with:
#          Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
#      or invoke the script directly:
#          powershell -ExecutionPolicy Bypass -File .\build.ps1
# =============================================================================

param(
    [switch] $Release,
    [switch] $CopyNative,
    [switch] $Quiet
)

$ErrorActionPreference = "Stop"

# -----------------------------------------------------------------------------
#  Helpers
# -----------------------------------------------------------------------------

function Write-Section([string]$title) {
    if ($Quiet) { return }
    Write-Host ""
    Write-Host "======================================================================" -ForegroundColor Cyan
    Write-Host "  $title" -ForegroundColor Cyan
    Write-Host "======================================================================" -ForegroundColor Cyan
}

function Write-Info([string]$msg) {
    if ($Quiet) { return }
    Write-Host "  $msg"
}

function Write-Ok([string]$msg) {
    Write-Host "  [OK]   $msg" -ForegroundColor Green
}

function Write-Warn([string]$msg) {
    Write-Host "  [WARN] $msg" -ForegroundColor Yellow
}

function Write-Err([string]$msg) {
    Write-Host "  [ERR]  $msg" -ForegroundColor Red
}

# Returns "windows", "macos", "linux", or "unknown".
# Uses the automatic variables available on PowerShell 6+ and falls back
# to $env:OS for Windows PowerShell 5.1.
function Get-HostPlatform {
    if ($IsWindows) { return "windows" }
    if ($IsMacOS)   { return "macos" }
    if ($IsLinux)   { return "linux" }
    if ($env:OS -eq "Windows_NT") { return "windows" }
    return "unknown"
}

function Get-NativeLibraryName([string]$platform) {
    switch ($platform) {
        "windows" { return "LingoFuse64.dll" }
        "macos"   { return "liblingofuse.dylib" }
        "linux"   { return "liblingofuse.so" }
        default   { return "" }
    }
}

function Get-NativeDependencies([string]$platform) {
    switch ($platform) {
        "windows" { return @("z_ipc_64.dll", "mimalloc64.dll") }
        "macos"   { return @("libz_ipc.dylib", "libmimalloc.dylib") }
        "linux"   { return @("libz_ipc.so", "libmimalloc.so") }
        default   { return @() }
    }
}

# -----------------------------------------------------------------------------
#  1. Locate the project root
# -----------------------------------------------------------------------------

$ProjectDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$ManifestPath = Join-Path $ProjectDir "Package.swift"

if (-not (Test-Path $ManifestPath)) {
    Write-Host "[FATAL] Package.swift not found in $ProjectDir" -ForegroundColor Red
    Write-Host "        Run this script from the swift/ directory." -ForegroundColor Red
    exit 2
}

# -----------------------------------------------------------------------------
#  2. Verify the Swift toolchain
# -----------------------------------------------------------------------------

try {
    $swiftCmd = Get-Command swift -ErrorAction Stop
    $SwiftExe = $swiftCmd.Source
} catch {
    Write-Host "[FATAL] Swift toolchain not found on PATH." -ForegroundColor Red
    Write-Host "        Install Swift 5.9 or later and ensure 'swift' is on PATH." -ForegroundColor Red
    exit 2
}

# -----------------------------------------------------------------------------
#  3. Banner
# -----------------------------------------------------------------------------

Write-Section "LingoFuse Swift Build"

$Configuration = if ($Release) { "release" } else { "debug" }
$arch = if ([System.Environment]::Is64BitOperatingSystem) { "x64" } else { "x86" }

Write-Info "Project directory : $ProjectDir"
Write-Info "Swift executable  : $SwiftExe"
Write-Info "Configuration     : $Configuration"
Write-Info "Platform          : $(Get-HostPlatform)"
Write-Info "Architecture      : $arch"

try {
    $swiftVersionLine = (& swift --version 2>&1 | Select-Object -First 1)
    Write-Info "Swift version     : $swiftVersionLine"
} catch {
    Write-Warn "Could not determine the Swift version."
}

# -----------------------------------------------------------------------------
#  4. Locate the native library
# -----------------------------------------------------------------------------

$platform = Get-HostPlatform
$nativeLibName = Get-NativeLibraryName $platform
$nativeDir = $null

if ([string]::IsNullOrEmpty($nativeLibName)) {
    Write-Warn "Unknown platform; the native library cannot be auto-detected."
} else {
    Write-Section "Native library"

    # Common candidate directories, in priority order.
    $candidates = @(
        (Join-Path $ProjectDir "..\Binary"),
        (Join-Path $ProjectDir "Binary"),
        (Join-Path $ProjectDir "native"),
        $ProjectDir
    )

    foreach ($dir in $candidates) {
        if (-not (Test-Path $dir)) { continue }
        $full = (Resolve-Path $dir).Path
        if (Test-Path (Join-Path $full $nativeLibName)) {
            $nativeDir = $full
            break
        }
    }

    if ($nativeDir) {
        Write-Ok "$nativeLibName found in $nativeDir"
    } else {
        Write-Warn "$nativeLibName not found in any of:"
        foreach ($c in $candidates) {
            Write-Host "           $c" -ForegroundColor DarkGray
        }
        Write-Warn "The build will proceed, but runtime tests will be skipped."
        Write-Warn "Add the native directory to PATH or use -CopyNative."
    }
}

# -----------------------------------------------------------------------------
#  5. Run swift build
# -----------------------------------------------------------------------------

Write-Section "Building"

$buildArgs = @("build")
if ($Release) {
    $buildArgs += "-c"
    $buildArgs += "release"
}

Write-Info "Command: swift $($buildArgs -join ' ')"
Write-Host ""

try {
    & swift @buildArgs
    $exitCode = $LASTEXITCODE
} catch {
    Write-Err "swift build threw an exception: $_"
    exit 1
}

if ($exitCode -ne 0) {
    Write-Err "swift build failed with exit code $exitCode"
    exit 1
}

Write-Ok "Build succeeded."

# -----------------------------------------------------------------------------
#  6. Optionally copy the native library to the build directory
# -----------------------------------------------------------------------------

if ($CopyNative) {
    Write-Section "Copying native library"

    if (-not $nativeDir) {
        Write-Err "Cannot copy: the native directory was not located."
        exit 1
    }

    $outDir = Join-Path $ProjectDir ".build\$Configuration"
    if (-not (Test-Path $outDir)) {
        Write-Err "Output directory not found: $outDir"
        exit 1
    }

    $filesToCopy = @($nativeLibName) + (Get-NativeDependencies $platform)
    foreach ($file in $filesToCopy) {
        $src = Join-Path $nativeDir $file
        if (-not (Test-Path $src)) {
            Write-Warn "Not found (skipped): $file"
            continue
        }
        $dst = Join-Path $outDir $file
        Copy-Item -Path $src -Destination $dst -Force
        Write-Ok "Copied $file"
    }
}

# -----------------------------------------------------------------------------
#  7. Done
# -----------------------------------------------------------------------------

Write-Section "Done"
Write-Info "Output directory: $ProjectDir\.build\$Configuration"
Write-Info "Next steps:"
Write-Info "    .\test.ps1"
Write-Info "    swift run CrossService"

exit 0