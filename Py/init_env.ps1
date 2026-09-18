#Requires -Version 5.1
<#
.SYNOPSIS
    Initialize the LingoFuse Python binding environment.

.DESCRIPTION
    Configures PYTHONPATH and PATH so that the `lingofuse` package can
    be imported and the native LingoFuse shared library can be located
    at runtime.

    TWO MODES OF OPERATION
    ----------------------
    1. PERSISTENT MODE  --  .\init_env.ps1
       Writes the required entries to the User scope of the Windows
       environment (HKCU\Environment). The change survives reboots
       and applies to every new shell opened afterwards.

       The CURRENT shell will NOT see the change, because a child
       process cannot modify its parent's environment. The script
       prints the exact one-line refresh command to run in the
       current window if you do not want to open a new one.

    2. SESSION MODE  --  . .\init_env.ps1
       Only modifies the current PowerShell session ($env:PYTHONPATH,
       $env:PATH). Nothing is written to the registry. Use this for
       throwaway shells, CI runners, or when you do not want to leave
       any trace on the machine.

    Both modes perform the same PYTHONPATH / PATH computation and end
    with the same `import lingofuse` verification step.

.PARAMETER NoBinary
    Do not add the sibling `..\Binary` directory to PATH. PYTHONPATH
    is still configured and verified.

.EXAMPLE
    .\init_env.ps1
    Persistently configure the environment, then open a new shell.

.EXAMPLE
    . .\init_env.ps1
    Configure only the current shell. No registry changes.

.EXAMPLE
    .\init_env.ps1 -NoBinary
    Persistently configure PYTHONPATH only; leave PATH untouched.
#>

param(
    [switch]$NoBinary
)

# ----------------------------------------------------------------------
# Determine the mode from how the script was invoked.
# ----------------------------------------------------------------------
# $MyInvocation.InvocationName is "." when the script is dot-sourced.
# It is the script path (or its name) in every other case.
$isDotSourced = ($MyInvocation.InvocationName -eq '.')

# ----------------------------------------------------------------------
# Resolve the script root directory.
# ----------------------------------------------------------------------
$scriptDir = $PSScriptRoot
if (-not $scriptDir) {
    $scriptDir = (Get-Location).Path
}
$scriptDir = $scriptDir.TrimEnd('\', '/')

Write-Host ""
Write-Host "Initializing LingoFuse Python Binding Environment" -ForegroundColor Cyan
Write-Host "Script root directory: $scriptDir" -ForegroundColor Gray
if ($isDotSourced) {
    Write-Host "Mode: SESSION (current shell only)" -ForegroundColor Gray
} else {
    Write-Host "Mode: PERSISTENT (User scope; new shells will pick it up)" -ForegroundColor Gray
}

# ----------------------------------------------------------------------
# Compute the target PATH entry (the sibling ..\Binary directory).
# ----------------------------------------------------------------------
$binaryDir = $null
if ($NoBinary) {
    Write-Host "[INFO] -NoBinary specified; PATH will not be modified." -ForegroundColor Gray
} else {
    $rawBinaryDir = Join-Path $scriptDir "..\Binary"
    $resolvedBinary = Resolve-Path $rawBinaryDir -ErrorAction SilentlyContinue
    if (-not $resolvedBinary) {
        Write-Host "[WARN] Binary directory does not exist: $rawBinaryDir" -ForegroundColor Yellow
        Write-Host "       PATH will not be modified." -ForegroundColor Yellow
    } else {
        $binaryDir = $resolvedBinary.Path.TrimEnd('\', '/')
    }
}

# ======================================================================
# PERSISTENT MODE  --  write to HKCU\Environment
# ======================================================================
if (-not $isDotSourced) {

    # ------------------------------------------------------------------
    # PYTHONPATH (User scope)
    # ------------------------------------------------------------------
    # PYTHONPATH has no Machine-level counterpart in standard Windows
    # installs, so reading and writing the User scope is safe and does
    # not clobber anything set by the system.
    $userPythonPath = [Environment]::GetEnvironmentVariable("PYTHONPATH", "User")
    $userPythonPaths = if ($userPythonPath) { $userPythonPath -split ';' } else { @() }

    if ($userPythonPaths -contains $scriptDir) {
        Write-Host "[OK] PYTHONPATH (User) already contains $scriptDir" -ForegroundColor Green
    } else {
        $newUserPythonPath = if ($userPythonPath) {
            "$scriptDir;$userPythonPath"
        } else {
            $scriptDir
        }
        [Environment]::SetEnvironmentVariable("PYTHONPATH", $newUserPythonPath, "User")
        Write-Host "[OK] Prepended $scriptDir to PYTHONPATH (User)" -ForegroundColor Green
    }

    # ------------------------------------------------------------------
    # PATH (User scope)
    # ------------------------------------------------------------------
    # IMPORTANT: we read and write ONLY the User scope here.
    #
    # The process PATH visible inside this shell is a merge of the
    # Machine and User scopes done by Windows at process creation. If
    # we wrote the merged value back to the User scope, the entire
    # system PATH (C:\Windows\System32, ...) would end up duplicated
    # in the user's registry hive -- a classic mistake that is very
    # annoying to clean up later.
    if ($binaryDir) {
        $userPath = [Environment]::GetEnvironmentVariable("PATH", "User")
        $userPaths = if ($userPath) { $userPath -split ';' } else { @() }

        if ($userPaths -contains $binaryDir) {
            Write-Host "[OK] PATH (User) already contains $binaryDir" -ForegroundColor Green
        } else {
            $newUserPath = if ($userPath) { "$binaryDir;$userPath" } else { $binaryDir }
            [Environment]::SetEnvironmentVariable("PATH", $newUserPath, "User")
            Write-Host "[OK] Prepended $binaryDir to PATH (User)" -ForegroundColor Green
        }
    }

    # ------------------------------------------------------------------
    # Mirror the changes into the CURRENT script process, so the
    # verification step at the bottom can actually import lingofuse.
    # These assignments are discarded when the script exits; they are
    # only here to make the verification honest.
    # ------------------------------------------------------------------
    if ($env:PYTHONPATH) {
        $env:PYTHONPATH = "$scriptDir;$env:PYTHONPATH"
    } else {
        $env:PYTHONPATH = $scriptDir
    }
    if ($binaryDir) {
        if ($env:PATH) {
            $env:PATH = "$binaryDir;$env:PATH"
        } else {
            $env:PATH = $binaryDir
        }
    }
}

# ======================================================================
# SESSION MODE  --  modify $env: only, do not touch the registry
# ======================================================================
if ($isDotSourced) {

    # --- PYTHONPATH ---
    $currentPYTHONPATH = [Environment]::GetEnvironmentVariable("PYTHONPATH", "Process")
    if ($currentPYTHONPATH) {
        $paths = $currentPYTHONPATH -split [IO.Path]::PathSeparator
        if ($paths -contains $scriptDir) {
            Write-Host "[OK] PYTHONPATH already contains $scriptDir" -ForegroundColor Green
        } else {
            $env:PYTHONPATH = "$scriptDir$([IO.Path]::PathSeparator)$currentPYTHONPATH"
            Write-Host "[OK] Prepended $scriptDir to PYTHONPATH" -ForegroundColor Green
        }
    } else {
        $env:PYTHONPATH = $scriptDir
        Write-Host "[OK] Set PYTHONPATH = $scriptDir" -ForegroundColor Green
    }

    # --- PATH ---
    if ($binaryDir) {
        $currentPATH = [Environment]::GetEnvironmentVariable("PATH", "Process")
        $paths = $currentPATH -split [IO.Path]::PathSeparator
        if ($paths -contains $binaryDir) {
            Write-Host "[OK] PATH already contains $binaryDir" -ForegroundColor Green
        } else {
            $env:PATH = "$binaryDir$([IO.Path]::PathSeparator)$currentPATH"
            Write-Host "[OK] Prepended $binaryDir to PATH" -ForegroundColor Green
        }
    }
}

# ----------------------------------------------------------------------
# Verification: `import lingofuse` must succeed with the active Python.
# ----------------------------------------------------------------------
Write-Host ""
Write-Host "Verifying lingofuse package..." -ForegroundColor Cyan

$pythonCmd = Get-Command python -ErrorAction SilentlyContinue
if (-not $pythonCmd) {
    Write-Host "[ERROR] 'python' is not on PATH. Install Python 3.7+ first." -ForegroundColor Red
} else {
    $testCmd = "import lingofuse; print('lingofuse imported successfully')"
    $output = & python -c $testCmd 2>&1
    if ($LASTEXITCODE -eq 0) {
        Write-Host "[OK] lingofuse package import successful." -ForegroundColor Green
    } else {
        Write-Host "[ERROR] Failed to import lingofuse. Please check PYTHONPATH." -ForegroundColor Red
        Write-Host "        Python output: $output" -ForegroundColor Red
    }
}

# ----------------------------------------------------------------------
# Summary
# ----------------------------------------------------------------------
Write-Host ""
if ($isDotSourced) {

    Write-Host "Current environment variable summary:" -ForegroundColor Cyan
    Write-Host "PYTHONPATH = $env:PYTHONPATH" -ForegroundColor Gray
    $pathPreview = ($env:PATH -split [IO.Path]::PathSeparator | Select-Object -First 3) -join ';'
    Write-Host "PATH (first 3 entries) = $pathPreview ..." -ForegroundColor Gray
    Write-Host ""
    Write-Host "[OK] Session environment initialized. This shell is ready." -ForegroundColor Cyan

} else {

    Write-Host "============================================================" -ForegroundColor Cyan
    Write-Host "  Persistent environment updated" -ForegroundColor Green
    Write-Host "============================================================" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "The changes were written to the User scope of the Windows" -ForegroundColor Gray
    Write-Host "environment and will apply automatically to every shell you" -ForegroundColor Gray
    Write-Host "open from now on." -ForegroundColor Gray
    Write-Host ""
    Write-Host "The CURRENT window cannot see them yet: a child process can" -ForegroundColor Yellow
    Write-Host "never modify its parent's environment." -ForegroundColor Yellow
    Write-Host ""
    Write-Host "Two options to use the new environment right now:" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "  (a) Open a new PowerShell window." -ForegroundColor Yellow
    Write-Host ""
    Write-Host "  (b) Run this line in the CURRENT window to reload the" -ForegroundColor Yellow
    Write-Host "      User-scope variables without restarting:" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "      `$env:PYTHONPATH = [Environment]::GetEnvironmentVariable('PYTHONPATH','User');" -ForegroundColor White
    Write-Host "      `$env:PATH = [Environment]::GetEnvironmentVariable('PATH','Machine') + ';' + [Environment]::GetEnvironmentVariable('PATH','User')" -ForegroundColor White
    Write-Host ""
}