<#
.SYNOPSIS
    Removes every build artefact produced by the LingoFuse C# binding.

.DESCRIPTION
    Recursively scans the repository for every C# project (*.csproj) and
    removes the bin/ and obj/ directories that MSBuild creates inside
    each project directory. Because the scan is dynamic, adding a new
    project, moving an existing one, or restructuring the repository
    does not require editing this script.

    The script does NOT touch source files, .git, .vs, or any file
    outside the build artefacts it is responsible for.

.PARAMETER Configuration
    The build configuration whose artefacts should be removed.

      All      (default)  Remove the entire bin/ and obj/ trees.
      Debug               Remove only bin/Debug and obj/Debug.
      Release             Remove only bin/Release and obj/Release.

    The "All" mode is the safest choice for a full clean; the narrower
    modes are useful when you want to rebuild one configuration while
    keeping the other intact.

.PARAMETER IncludePackages
    When set, also removes:
      - packages/
      - artifacts/
      - TestResults/
      - any stray *.nupkg / *.snupkg under the repository root

.EXAMPLE
    .\clean.ps1
    Removes every bin/ and obj/ directory under the repository root.

.EXAMPLE
    .\clean.ps1 -Configuration Release
    Removes only Release artefacts, leaving Debug output intact.

.EXAMPLE
    .\clean.ps1 -IncludePackages
    Full clean, including local NuGet packages and test results.

.EXAMPLE
    .\clean.ps1 -Verbose
    Prints each directory as it is removed.
#>

[CmdletBinding()]
param(
    [ValidateSet('Debug', 'Release', 'All')]
    [string]$Configuration = 'All',

    [switch]$IncludePackages
)

$ErrorActionPreference = 'Stop'

$RepoRoot = $PSScriptRoot

# ---------------------------------------------------------------------------
# Header
# ---------------------------------------------------------------------------

Write-Host ''
Write-Host '=== LingoFuse C# binding - clean ===' -ForegroundColor Cyan
Write-Host "Repository root : $RepoRoot"
Write-Host "Configuration   : $Configuration"
Write-Host "Include packages: $($IncludePackages.IsPresent)"
Write-Host ''

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

function Remove-DirectoryIfExists {
    param(
        [Parameter(Mandatory)] [string]$Path
    )

    if (Test-Path -LiteralPath $Path) {
        Write-Verbose "Removing: $Path"
        Remove-Item -LiteralPath $Path -Recurse -Force
        return $true
    }
    return $false
}

# ---------------------------------------------------------------------------
# Step 1: remove bin/ and obj/ for every C# project
# ---------------------------------------------------------------------------

Write-Host '[1/2] Removing bin/ and obj/ directories...' -ForegroundColor Yellow

# Discover every *.csproj under the repository root, excluding anything
# that lives inside an existing bin/ or obj/ directory.
$csprojFiles = @(
    Get-ChildItem -LiteralPath $RepoRoot -Recurse -File -Filter '*.csproj' `
        -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -notmatch '[\\/](bin|obj)[\\/]' } |
        Sort-Object FullName
)

if ($csprojFiles.Count -eq 0) {
    Write-Host '  No .csproj files found under the repository root.' -ForegroundColor DarkYellow
    Write-Host '  Nothing to clean.' -ForegroundColor DarkYellow
} else {
    Write-Host "  Found $($csprojFiles.Count) project file(s)."
}

$removedCount = 0

foreach ($csproj in $csprojFiles) {
    $projectDir = $csproj.Directory.FullName

    if ($Configuration -eq 'All') {
        # Remove the entire bin/ and obj/ trees.
        foreach ($name in @('bin', 'obj')) {
            $target = Join-Path $projectDir $name
            if (Remove-DirectoryIfExists -Path $target) {
                $removedCount++
            }
        }
    } else {
        # Remove only the selected configuration subdirectory.
        foreach ($parent in @('bin', 'obj')) {
            $target = Join-Path $projectDir (Join-Path $parent $Configuration)
            if (Remove-DirectoryIfExists -Path $target) {
                $removedCount++
            }
        }
    }
}

$directoriesWord = if ($removedCount -eq 1) { 'directory' } else { 'directories' }
Write-Host "  Removed $removedCount $directoriesWord." -ForegroundColor Green

# ---------------------------------------------------------------------------
# Step 2: optionally remove local NuGet packages and other build artefacts
# ---------------------------------------------------------------------------

if ($IncludePackages) {
    Write-Host '[2/2] Removing local NuGet packages and test artefacts...' `
        -ForegroundColor Yellow

    $removedItems = 0

    foreach ($dir in @('packages', 'artifacts', 'TestResults')) {
        $target = Join-Path $RepoRoot $dir
        if (Remove-DirectoryIfExists -Path $target) {
            $removedItems++
        }
    }

    # Stray .nupkg / .snupkg files anywhere under the repository root,
    # excluding anything already covered by the bin/obj removal above.
    $packageFiles = @(
        Get-ChildItem -LiteralPath $RepoRoot -Recurse -File `
            -Include '*.nupkg', '*.snupkg' -ErrorAction SilentlyContinue |
            Where-Object { $_.FullName -notmatch '[\\/](bin|obj)[\\/]' }
    )
    foreach ($file in $packageFiles) {
        Write-Verbose "Removing: $($file.FullName)"
        Remove-Item -LiteralPath $file.FullName -Force
        $removedItems++
    }

    $itemsWord = if ($removedItems -eq 1) { 'item' } else { 'items' }
    Write-Host "  Removed $removedItems package $itemsWord." -ForegroundColor Green
} else {
    Write-Host '[2/2] Skipping package cleanup (use -IncludePackages to enable).' `
        -ForegroundColor DarkGray
}

# ---------------------------------------------------------------------------
# Done
# ---------------------------------------------------------------------------

Write-Host ''
Write-Host 'Clean completed successfully.' -ForegroundColor Green
Write-Host ''