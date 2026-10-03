# =============================================================================
#  build.ps1 - Build all LingoFuse Zig artifacts.
# -----------------------------------------------------------------------------
#  Steps
#  -----
#    1. Verify that the Zig toolchain is available on PATH.
#    2. Print the Zig version for the build log.
#    3. Run `zig build` to compile every smoke executable and every
#       cross-process demo.
#
#  Parameters
#  ----------
#    -Optimize   Selects the Zig optimization mode. Accepted values:
#                Debug (default), ReleaseSafe, ReleaseFast, ReleaseSmall.
#    -Quiet      Suppresses per-step console output. Only the final
#                summary is printed.
#
#  Exit codes
#  ----------
#    0  every artifact built successfully
#    1  the Zig toolchain is not available
#    2  `zig build` failed
#
#  Example
#  -------
#    .\build.ps1
#    .\build.ps1 -Optimize ReleaseFast
#    .\build.ps1 -Quiet
# =============================================================================

[CmdletBinding()]
param(
    [ValidateSet('Debug', 'ReleaseSafe', 'ReleaseFast', 'ReleaseSmall')]
    [string]$Optimize = 'Debug',

    [switch]$Quiet
)

$ErrorActionPreference = 'Stop'

# -----------------------------------------------------------------------------
# Helper: print a status line unless -Quiet is set.
# -----------------------------------------------------------------------------
function Write-Status {
    param(
        [string]$Message,
        [string]$Color = 'Cyan'
    )
    if (-not $Quiet) {
        Write-Host $Message -ForegroundColor $Color
    }
}

# -----------------------------------------------------------------------------
# Helper: print a line unconditionally (used for the final summary).
# -----------------------------------------------------------------------------
function Write-Always {
    param(
        [string]$Message,
        [string]$Color = 'White'
    )
    Write-Host $Message -ForegroundColor $Color
}

# -----------------------------------------------------------------------------
# Move to the script's own directory so the build always runs from the
# project root, regardless of where the user invoked the script from.
# -----------------------------------------------------------------------------
$Root = $PSScriptRoot
Set-Location $Root

Write-Status "================================================================"
Write-Status "  LingoFuse Zig binding - build"
Write-Status "================================================================"
Write-Status "  Project root : $Root"
Write-Status "  Optimize     : $Optimize"
Write-Status "================================================================"

# -----------------------------------------------------------------------------
# Step 1 - Zig toolchain check.
# -----------------------------------------------------------------------------
Write-Status ""
Write-Status "[1/2] Checking Zig toolchain..."

$zigCmd = Get-Command zig -ErrorAction SilentlyContinue
if ($null -eq $zigCmd) {
    Write-Always "[FATAL] 'zig' is not on PATH." 'Red'
    Write-Always "        Install Zig 0.17.0 or later, or add its directory" 'Red'
    Write-Always "        to the PATH environment variable." 'Red'
    exit 1
}

$zigVersion = (& zig version) 2>&1
Write-Status "      zig version: $zigVersion"

# -----------------------------------------------------------------------------
# Step 2 - `zig build`.
# -----------------------------------------------------------------------------
Write-Status ""
Write-Status "[2/2] Running: zig build -Doptimize=$Optimize"
Write-Status ""

& zig build "-Doptimize=$Optimize"
$buildExit = $LASTEXITCODE
if ($null -eq $buildExit) { $buildExit = 0 }

if ($buildExit -ne 0) {
    Write-Always ""
    Write-Always "[FAIL] 'zig build' exited with code $buildExit." 'Red'
    exit 2
}

# -----------------------------------------------------------------------------
# Summary.
# -----------------------------------------------------------------------------
Write-Always ""
Write-Always "================================================================" 'Green'
Write-Always "  Build succeeded." 'Green'
Write-Always "================================================================" 'Green'
Write-Always "  Artifacts are in: $Root\zig-out\bin" 'Green'
Write-Always "================================================================" 'Green'

exit 0