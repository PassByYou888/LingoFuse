<#
.SYNOPSIS
    Run the LingoFuse Java binding test suite.

.DESCRIPTION
    Verifies the environment, then runs the JUnit 5 test suite through
    Maven Surefire.

    By default, runs every test with a clean build. Use -Class and
    -Method to narrow the run, and -NoClean to reuse previous build
    output.

.PARAMETER Class
    Fully-qualified test class name, for example
    "lingofuse.DataHandleSmokeTest".

.PARAMETER Method
    Test method name. Requires -Class to be specified.

.PARAMETER NoClean
    Skip the "mvn clean" step and reuse previous build output. Useful
    when iterating on a single test.

.EXAMPLE
    .\test.ps1
    .\test.ps1 -NoClean
    .\test.ps1 -Class lingofuse.DataHandleSmokeTest
    .\test.ps1 -Class lingofuse.DataHandleSmokeTest -Method writeStringAppendsNul
#>

[CmdletBinding()]
param(
    [string]$Class,
    [string]$Method,
    [switch]$NoClean
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

# --- Argument validation ----------------------------------------------------

if ($Method -and -not $Class) {
    Write-Err "-Method requires -Class to be specified."
    exit 1
}

# --- Header -----------------------------------------------------------------

Write-Info "=== LingoFuse Java binding - test ==="
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

# Native library check: informational. Tests that touch the native
# library will fail with UnsatisfiedLinkError if it is not reachable.
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
    Write-Warn2 "Tests that invoke the native library may fail."
    Write-Warn2 "Expected names: $($nativeNames -join ', ')"
}

Write-Info ""

# --- Compose the Maven command ---------------------------------------------

$mvnArgs = @()
if ($NoClean) {
    Write-Info "Skipping clean (NoClean specified)."
} else {
    $mvnArgs += "clean"
}

if ($Class) {
    if ($Method) {
        $testPattern = "$Class#$Method"
        Write-Info "Running single test: $testPattern"
    } else {
        $testPattern = $Class
        Write-Info "Running test class: $testPattern"
    }
    $mvnArgs += "test"
    $mvnArgs += "-Dtest=$testPattern"
} else {
    Write-Info "Running the full test suite."
    $mvnArgs += "test"
}

Write-Info ""
Write-Info "Command: mvn $($mvnArgs -join ' ')"
Write-Info ""

# --- Run --------------------------------------------------------------------

& mvn -B @mvnArgs
$exitCode = $LASTEXITCODE

# --- Summary ----------------------------------------------------------------

Write-Info ""
if ($exitCode -eq 0) {
    Write-Ok "All tests passed."
} else {
    Write-Err "Tests failed (exit code $exitCode)."
    Write-Err "Surefire reports: $(Join-Path (Get-Location) 'target\surefire-reports')"
}

exit $exitCode