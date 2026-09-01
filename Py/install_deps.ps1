<#
.SYNOPSIS
    Install Python dependencies required for LingoFuse Python bindings.
.DESCRIPTION
    This script automatically installs core Python packages needed to run LingoFuse
    (e.g., Flask for the HTTP bridge). It also checks for the presence of the
    LingoFuse dynamic library. Administrator privileges are recommended if installing
    packages globally. To install for the current user only, add the --user flag
    manually (this script uses pip install without --user by default).
.EXAMPLE
    .\install_deps.ps1
    Automatically detect and install dependencies.
#>

Write-Host "============================================================" -ForegroundColor Cyan
Write-Host "  LingoFuse Python Binding – Dependency Installation" -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host ""

# 1. Check if Python is available
try {
    $pythonVersion = python --version 2>&1
    Write-Host "[OK] Python detected: $pythonVersion" -ForegroundColor Green
} catch {
    Write-Host "[ERROR] Python not found. Please install Python 3.6+ and add it to PATH." -ForegroundColor Red
    exit 1
}

# 2. Check if pip is available
try {
    $pipVersion = pip --version 2>&1
    Write-Host "[OK] pip detected: $pipVersion" -ForegroundColor Green
} catch {
    Write-Host "[ERROR] pip not found. Ensure Python installation includes pip." -ForegroundColor Red
    exit 1
}

# 3. Install required dependencies (Flask for the HTTP bridge; core libraries are included in the lingofuse package)
Write-Host ""
Write-Host "Installing Flask (required for the HTTP bridge)..." -ForegroundColor Yellow
pip install flask
if ($LASTEXITCODE -ne 0) {
    Write-Host "[ERROR] Flask installation failed. Please run manually: pip install flask" -ForegroundColor Red
    exit 1
} else {
    Write-Host "[OK] Flask installed successfully." -ForegroundColor Green
}

# 4. Check for the dynamic library (optional)
Write-Host ""
$libName = "LingoFuse64.dll"  # Default name on Windows
# For Linux/macOS, detection could be extended (liblingofuse.so / .dylib), but this script is primarily Windows-oriented.
$binaryDir = Join-Path $PSScriptRoot "..\Binary"
if (Test-Path $binaryDir) {
    $libPath = Join-Path $binaryDir $libName
    if (Test-Path $libPath) {
        Write-Host "[OK] Found dynamic library: $libPath" -ForegroundColor Green
    } else {
        Write-Host "[WARNING] Did not find $libName in the Binary directory. Please ensure the LingoFuse dynamic library is placed there." -ForegroundColor Yellow
    }
} else {
    Write-Host "[WARNING] Binary directory not found. Please place the LingoFuse dynamic library in the Binary directory or in the system PATH." -ForegroundColor Yellow
}

# 5. Suggest environment variable settings
Write-Host ""
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host "  Environment Variables Recommendation" -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host "If you haven't set PYTHONPATH and PATH yet, run the following commands (or execute init_env.ps1):"
Write-Host ""
Write-Host "   `$env:PYTHONPATH = `"$PSScriptRoot`""
Write-Host "   `$env:PATH = `"$binaryDir;$env:PATH`""
Write-Host ""
Write-Host "Or simply run: .\init_env.ps1"
Write-Host ""
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host "  Installation complete! You can now start using LingoFuse Python bindings." -ForegroundColor Green
Write-Host "  Refer to the documentation for further steps." -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor Cyan