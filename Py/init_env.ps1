<#
.SYNOPSIS
    Initialize the LingoFuse Python binding environment by setting PYTHONPATH and PATH.
.DESCRIPTION
    This script sets environment variables for the current PowerShell session so that
    the lingofuse package can be imported. Optionally, it adds the Binary directory
    (which contains LingoFuse64.dll and its dependencies) to the system PATH.
    It is recommended to run this script before executing any LingoFuse Python programs.
.PARAMETER NoBinary
    If specified, the Binary directory is NOT added to PATH (it is added by default).
.EXAMPLE
    .\init_env.ps1
    Initialize the environment and add Binary to PATH.
.EXAMPLE
    .\init_env.ps1 -NoBinary
    Only set PYTHONPATH, do not modify PATH.
#>

param(
    [switch]$NoBinary
)

# Get the script directory (the root of the Py folder)
$scriptDir = $PSScriptRoot
if (-not $scriptDir) {
    $scriptDir = (Get-Location).Path
}

Write-Host "🔧 Initializing LingoFuse Python Binding Environment" -ForegroundColor Cyan
Write-Host "Script root directory: $scriptDir" -ForegroundColor Gray

# ---------- Set PYTHONPATH ----------
$currentPYTHONPATH = [Environment]::GetEnvironmentVariable("PYTHONPATH", "Process")
if ($currentPYTHONPATH) {
    $paths = $currentPYTHONPATH -split [IO.Path]::PathSeparator
    if ($paths -contains $scriptDir) {
        Write-Host "✅ PYTHONPATH already contains $scriptDir, no change needed." -ForegroundColor Green
    } else {
        $env:PYTHONPATH = "$scriptDir;$currentPYTHONPATH"
        Write-Host "✅ Appended $scriptDir to PYTHONPATH." -ForegroundColor Green
    }
} else {
    $env:PYTHONPATH = $scriptDir
    Write-Host "✅ Set PYTHONPATH = $scriptDir" -ForegroundColor Green
}

# ---------- Set PATH (add Binary directory) ----------
if (-not $NoBinary) {
    $binaryDir = Join-Path $scriptDir "..\Binary"
    $binaryDir = Resolve-Path $binaryDir -ErrorAction SilentlyContinue
    if (-not $binaryDir) {
        Write-Host "⚠️ Warning: Binary directory does not exist: $binaryDir. Skipping PATH modification." -ForegroundColor Yellow
    } else {
        $currentPATH = [Environment]::GetEnvironmentVariable("PATH", "Process")
        $paths = $currentPATH -split [IO.Path]::PathSeparator
        if ($paths -contains $binaryDir) {
            Write-Host "✅ PATH already contains $binaryDir, no change needed." -ForegroundColor Green
        } else {
            $env:PATH = "$binaryDir;$currentPATH"
            Write-Host "✅ Prepended $binaryDir to PATH." -ForegroundColor Green
        }
    }
} else {
    Write-Host "ℹ️ According to -NoBinary, PATH was not modified." -ForegroundColor Gray
}

# ---------- Verify that the lingofuse package can be imported ----------
Write-Host "`n🔍 Verifying lingofuse package..." -ForegroundColor Cyan
$testCmd = "import lingofuse; print('lingofuse imported successfully')"
try {
    $output = python -c $testCmd 2>&1
    if ($LASTEXITCODE -eq 0) {
        Write-Host "✅ lingofuse package import successful." -ForegroundColor Green
    } else {
        Write-Host "❌ Failed to import lingofuse. Please check PYTHONPATH settings." -ForegroundColor Red
        Write-Host "Error output: $output" -ForegroundColor Red
    }
} catch {
    Write-Host "❌ Cannot run python command. Ensure Python is installed and in PATH." -ForegroundColor Red
}

# ---------- Show final environment variables ----------
Write-Host "`n📋 Current environment variable summary:" -ForegroundColor Cyan
Write-Host "PYTHONPATH = $env:PYTHONPATH" -ForegroundColor Gray
Write-Host "PATH (first 3 entries) = $($env:PATH -split [IO.Path]::PathSeparator | Select-Object -First 3) ..." -ForegroundColor Gray
Write-Host "`n✅ Environment initialization complete. You can now run LingoFuse Python programs." -ForegroundColor Cyan