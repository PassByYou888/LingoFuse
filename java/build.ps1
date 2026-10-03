<#
.SYNOPSIS
    Build the LingoFuse Java binding.

.DESCRIPTION
    Verifies the JDK and Maven installation, then compiles the binding
    and the test sources.

    By default, runs a full clean build ("mvn clean compile"). Pass
    -Incremental to skip the clean step and only recompile changed
    sources.

.PARAMETER Incremental
    Do not run "mvn clean"; just recompile the sources that changed.

.PARAMETER SkipTestCompile
    Only compile the main sources; do not compile the test sources.

.EXAMPLE
    .\build.ps1
    .\build.ps1 -Incremental
    .\build.ps1 -SkipTestCompile
#>

[CmdletBinding()]
param(
    [switch]$Incremental,
    [switch]$SkipTestCompile
)

$ErrorActionPreference = 'Stop'

# --- Output helpers ---------------------------------------------------------

function Write-Info  { param([string]$m) Write-Host "[INFO]  $m" -ForegroundColor Cyan }
function Write-Ok    { param([string]$m) Write-Host "[OK]    $m" -ForegroundColor Green }
function Write-Warn2 { param([string]$m) Write-Host "[WARN]  $m" -ForegroundColor Yellow }
function Write-Err   { param([string]$m) Write-Host "[ERROR] $m" -ForegroundColor Red }

function Assert-Command {
    param([Parameter(Mandatory=$true)][string]$Name)
    $cmd = Get-Command $Name -ErrorAction SilentlyContinue
    if (-not $cmd) {
        Write-Err "Command '$Name' not found on PATH."
        exit 1
    }
    return $cmd.Source
}

function Get-JavaMajorVersion {
    try {
        $out = (& java -version 2>&1 | Out-String)
        if ($out -match 'version "(\d+)') {
            return [int]$Matches[1]
        }
    } catch {
        # ignored
    }
    return -1
}

# --- Header -----------------------------------------------------------------

Write-Info "=== LingoFuse Java binding - build ==="
Write-Info "Working directory: $(Get-Location)"
Write-Info ""

# --- Preflight --------------------------------------------------------------

$mvnPath = Assert-Command -Name "mvn"
Write-Ok "Maven found: $mvnPath"

$javaPath = Assert-Command -Name "java"
Write-Ok "Java found:  $javaPath"

$javaMajor = Get-JavaMajorVersion
if ($javaMajor -lt 22) {
    Write-Err "JDK 22 or higher is required. Detected major version: $javaMajor"
    Write-Err "Install JDK 25 from https://adoptium.net/temurin/releases/"
    exit 1
}
Write-Ok "JDK major version: $javaMajor"

# Native library check: informational only. The library may still be
# discoverable through PATH / java.library.path / system loader paths.
$nativeNames = @("LingoFuse64.dll", "LingoFuse32.dll",
                 "liblingofuse.so", "liblingofuse.dylib")
$nativeFound = $false
foreach ($n in $nativeNames) {
    if (Test-Path -LiteralPath $n) {
        Write-Ok "Native library present in working directory: $n"
        $nativeFound = $true
        break
    }
}
if (-not $nativeFound) {
    Write-Warn2 "Native library not found in the working directory."
    Write-Warn2 "Expected names: $($nativeNames -join ', ')"
    Write-Warn2 "It may still be resolved through PATH or java.library.path."
}

Write-Info ""

# --- Build ------------------------------------------------------------------

if ($Incremental) {
    Write-Info "Running incremental compile (no clean)..."
    & mvn -B compile
    if ($LASTEXITCODE -ne 0) {
        Write-Err "Compile failed (exit code $LASTEXITCODE)."
        exit $LASTEXITCODE
    }
} else {
    Write-Info "Running clean compile..."
    & mvn -B clean compile
    if ($LASTEXITCODE -ne 0) {
        Write-Err "Compile failed (exit code $LASTEXITCODE)."
        exit $LASTEXITCODE
    }
}

if (-not $SkipTestCompile) {
    Write-Info ""
    Write-Info "Compiling test sources..."
    & mvn -B test-compile
    if ($LASTEXITCODE -ne 0) {
        Write-Err "Test compile failed (exit code $LASTEXITCODE)."
        exit $LASTEXITCODE
    }
}

# --- Summary ----------------------------------------------------------------

Write-Info ""
Write-Ok "Build succeeded."
Write-Ok "Classes: $(Join-Path (Get-Location) 'target\classes')"
if (-not $SkipTestCompile) {
    Write-Ok "Test classes: $(Join-Path (Get-Location) 'target\test-classes')"
}