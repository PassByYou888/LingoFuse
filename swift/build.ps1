# =============================================================================
#  build.ps1
# -----------------------------------------------------------------------------
#  Thin wrapper around `swift build`.
#
#  What this script does NOT do:
#    - It does not filter, rewrite, or buffer the Swift compiler output.
#    - It does not re-print the output through Write-Host.
#    - It does not parse the output for warnings or errors.
#
#  What this script does:
#    1. Optionally sets the console output encoding to UTF-8 so that the
#       native Swift output is decoded correctly on Windows PowerShell.
#       Without this, the Swift progress glyph "…" is mangled by the
#       legacy console code page. Pass -NoEncoding to skip this step.
#    2. Locates the project root and the Swift toolchain.
#    3. Locates the native LingoFuse library.
#    4. Runs `swift build` and lets its output go straight to the terminal.
#    5. Optionally copies the native library next to the built executables.
#
#  Usage:
#      .\build.ps1
#      .\build.ps1 -Release
#      .\build.ps1 -CopyNative
#      .\build.ps1 -Release -CopyNative -Quiet
#      .\build.ps1 -NoEncoding
#
#  Exit codes:
#      0  build succeeded
#      1  build failed
#      2  startup error (Swift not found, Package.swift missing, ...)
# =============================================================================

param(
    [switch] $Release,
    [switch] $CopyNative,
    [switch] $Quiet,
    [switch] $NoEncoding
)

$ErrorActionPreference = "Stop"

# -----------------------------------------------------------------------------
#  Console output encoding
#
#  Swift emits UTF-8. Windows PowerShell 5.1 decodes native process output
#  using the active console code page (CP936 on Simplified Chinese
#  Windows, CP1252 on Western Windows), which mangles multi-byte glyphs
#  such as the progress ellipsis "…" (E2 80 A6).
#
#  Setting [Console]::OutputEncoding to UTF-8 makes the decoding correct.
#  This is a decoding hint, not a transformation: the bytes produced by
#  Swift are unchanged.
#
#  Pass -NoEncoding to skip this step entirely and let PowerShell use its
#  default behaviour. On PowerShell 7+ the default is already UTF-8, so
#  the flag has no observable effect there.
# -----------------------------------------------------------------------------

if (-not $NoEncoding) {
    try {
        [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
        $OutputEncoding           = [System.Text.Encoding]::UTF8
    } catch {
        # Some hosts do not expose both knobs; ignore and continue.
    }
}

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
#
#  The invocation is a direct call. No pipeline, no ForEach-Object, no
#  Write-Host. Everything the compiler prints goes straight to the
#  terminal, with all its colours, progress updates, and warnings.
# -----------------------------------------------------------------------------

Write-Section "Building"

$buildArgs = @("build")
if ($Release) {
    $buildArgs += "-c"
    $buildArgs += "release"
}

Write-Info "Command: swift $($buildArgs -join ' ')"
Write-Host ""

& swift @buildArgs
$exitCode = $LASTEXITCODE

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