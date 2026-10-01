<#
.SYNOPSIS
    Builds the LingoFuse C# binding solution.

.DESCRIPTION
    Locates lf_csharp.sln (in the same directory as this script) and
    builds it. When -Project is given, builds only the specified .csproj
    instead. When no solution file exists, falls back to recursively
    discovering every *.csproj under the script directory.

    Optionally packs NuGet packages, runs test projects, and cleans
    before building.

    The repository layout this script expects (documentation only; the
    runtime logic is layout-independent):

        lf_csharp.sln
        CrossCall/CrossCall.csproj
        CrossNode/CrossNode.csproj
        crossService/crossService.csproj
        src/LingoFuse_cs/LingoFuse_cs.csproj     (library)
        test/test.csproj                         (test runner)

    Only lf_csharp.sln and the recursive *.csproj scan are consulted at
    run time; the list above is documentation, not configuration.

.PARAMETER Configuration
    Build configuration. Accepts Debug (default) or Release.

.PARAMETER Target
    What to do after building:

      Build  (default)  Restore + build.
      Pack              Build + produce .nupkg files in artifacts/.
                        Pack failures for non-packable projects are
                        reported as warnings and do not abort the run.
      Test              Build + run every test project.

.PARAMETER Project
    Optional. When set, only the specified project is built (or packed
    or tested). Accepts an absolute path or a path relative to the
    current working directory.

.PARAMETER Clean
    Run clean.ps1 before building.

.PARAMETER NoRestore
    Skip the explicit `dotnet restore` step. Useful in CI environments
    where the restore has already been performed.

.EXAMPLE
    .\build.ps1
    Debug build of lf_csharp.sln.

.EXAMPLE
    .\build.ps1 -Configuration Release -Target Pack
    Release build + NuGet packages in artifacts/.

.EXAMPLE
    .\build.ps1 -Clean -Target Test
    Clean, then build and run every test project.

.EXAMPLE
    .\build.ps1 -Project .\src\LingoFuse_cs\LingoFuse_cs.csproj
    Build only the LingoFuse binding library.

.EXAMPLE
    .\build.ps1 -Verbose
    Prints each build step in detail.

.NOTES
    IMPORTANT - PowerShell variable names are case-insensitive.
    The -Target parameter and any loop variable must NOT share a
    name even with different casing. In this script the build loop
    uses $item, never $target, so the ValidateSet on $Target cannot
    be triggered by an assignment inside the loop.
#>

[CmdletBinding()]
param(
    [ValidateSet('Debug', 'Release')]
    [string]$Configuration = 'Debug',

    [ValidateSet('Build', 'Pack', 'Test')]
    [string]$Target = 'Build',

    [string]$Project,

    [switch]$Clean,
    [switch]$NoRestore
)

$ErrorActionPreference = 'Stop'

$RepoRoot     = $PSScriptRoot
$ArtifactsDir = Join-Path $RepoRoot 'artifacts'
$SolutionFile = Join-Path $RepoRoot 'lf_csharp.sln'

# ---------------------------------------------------------------------------
# Header
# ---------------------------------------------------------------------------

Write-Host ''
Write-Host '=== LingoFuse C# binding - build ===' -ForegroundColor Cyan
Write-Host "Script dir      : $RepoRoot"
Write-Host "Configuration   : $Configuration"
Write-Host "Target          : $Target"
if ($Project) {
    Write-Host "Project         : $Project"
}
Write-Host ''

# ---------------------------------------------------------------------------
# Pre-flight: verify the .NET SDK is available
# ---------------------------------------------------------------------------

$dotnet = Get-Command dotnet -ErrorAction SilentlyContinue
if (-not $dotnet) {
    Write-Host 'ERROR: the dotnet CLI was not found on PATH.' -ForegroundColor Red
    Write-Host '       Install the .NET 8 SDK from https://dotnet.microsoft.com/' -ForegroundColor Red
    exit 1
}
Write-Host ("dotnet SDK      : " + (& dotnet --version)) -ForegroundColor DarkGray
Write-Host ''

# ---------------------------------------------------------------------------
# Determine the build target(s)
# ---------------------------------------------------------------------------
#
# Priority:
#   1. -Project <path>      -> build that single .csproj
#   2. lf_csharp.sln        -> build the solution
#   3. recursive *.csproj   -> build every project found under $RepoRoot
#
# NOTE: the loop variable used everywhere below is $item, NOT $target.
# PowerShell treats variable names case-insensitively, so using $target
# here would overwrite the -Target parameter and trigger its ValidateSet
# on the first assignment.

$buildTargets = @()
$useSolution  = $false

if ($Project) {
    $resolved = Resolve-Path -LiteralPath $Project -ErrorAction SilentlyContinue
    if (-not $resolved) {
        Write-Host "ERROR: project file not found: $Project" -ForegroundColor Red
        exit 1
    }
    $buildTargets = @($resolved.Path)
    Write-Host "Single-project mode: $(Split-Path -Leaf $buildTargets[0])" -ForegroundColor DarkGray
}
elseif (Test-Path -LiteralPath $SolutionFile) {
    $buildTargets = @($SolutionFile)
    $useSolution  = $true
    Write-Host "Solution mode: $(Split-Path -Leaf $SolutionFile)" -ForegroundColor DarkGray
}
else {
    $buildTargets = @(
        Get-ChildItem -LiteralPath $RepoRoot -Recurse -File -Filter '*.csproj' `
            -ErrorAction SilentlyContinue |
            Where-Object { $_.FullName -notmatch '[\\/](bin|obj)[\\/]' } |
            Sort-Object FullName |
            ForEach-Object { $_.FullName }
    )
    if ($buildTargets.Count -eq 0) {
        Write-Host 'ERROR: no solution and no .csproj file found.' -ForegroundColor Red
        exit 1
    }
    Write-Host "Found $($buildTargets.Count) project(s):" -ForegroundColor DarkGray
    foreach ($item in $buildTargets) {
        $rel = $item.Substring($RepoRoot.Length).TrimStart('\', '/')
        Write-Host "  - $rel" -ForegroundColor DarkGray
    }
}
Write-Host ''

# ---------------------------------------------------------------------------
# Step 0 (optional): clean
# ---------------------------------------------------------------------------

if ($Clean) {
    $cleanScript = Join-Path $RepoRoot 'clean.ps1'
    if (Test-Path -LiteralPath $cleanScript) {
        Write-Host '[0/3] Running clean.ps1...' -ForegroundColor Yellow
        # clean.ps1 sets $ErrorActionPreference = 'Stop' and uses
        # Remove-Item, so a real failure terminates this script. There
        # is no $LASTEXITCODE to check for a PowerShell script call.
        & $cleanScript -Configuration $Configuration
    }
    else {
        Write-Host '[0/3] clean.ps1 not found; skipping.' -ForegroundColor DarkYellow
    }
}

# ---------------------------------------------------------------------------
# Common settings
# ---------------------------------------------------------------------------

$verbosity = if ($VerbosePreference -eq 'Continue') { 'detailed' } else { 'minimal' }

# ---------------------------------------------------------------------------
# Step 1: restore
# ---------------------------------------------------------------------------

if (-not $NoRestore) {
    Write-Host '[1/3] Restoring NuGet packages...' -ForegroundColor Yellow

    foreach ($item in $buildTargets) {
        $name = Split-Path -Leaf $item
        Write-Host "  Restoring: $name" -ForegroundColor DarkGray

        & dotnet restore "$item"
        if ($LASTEXITCODE -ne 0) {
            Write-Host "ERROR: dotnet restore failed for $name" -ForegroundColor Red
            exit $LASTEXITCODE
        }
    }
    Write-Host '  Restore completed.' -ForegroundColor Green
}
else {
    Write-Host '[1/3] Skipping restore (-NoRestore).' -ForegroundColor DarkGray
}

# ---------------------------------------------------------------------------
# Step 2: build
# ---------------------------------------------------------------------------

Write-Host '[2/3] Building...' -ForegroundColor Yellow

foreach ($item in $buildTargets) {
    $name = Split-Path -Leaf $item
    Write-Host "  Building: $name" -ForegroundColor DarkGray

    & dotnet build "$item" `
        -c $Configuration `
        --no-restore `
        -v $verbosity `
        -p:ContinuousIntegrationBuild=true

    if ($LASTEXITCODE -ne 0) {
        Write-Host "ERROR: dotnet build failed for $name" -ForegroundColor Red
        exit $LASTEXITCODE
    }
}
Write-Host '  Build completed.' -ForegroundColor Green

# ---------------------------------------------------------------------------
# Step 3: target-specific action
# ---------------------------------------------------------------------------

switch ($Target) {

    'Build' {
        Write-Host '[3/3] Build target complete.' -ForegroundColor Green
    }

    'Pack' {
        Write-Host '[3/3] Packing NuGet packages...' -ForegroundColor Yellow

        if (-not (Test-Path -LiteralPath $ArtifactsDir)) {
            New-Item -ItemType Directory -Path $ArtifactsDir | Out-Null
        }

        # A .sln cannot be packed directly. In solution mode we fall
        # back to packing every discovered .csproj; in single-project
        # or recursive mode we already have the list.
        if ($useSolution) {
            $packTargets = @(
                Get-ChildItem -LiteralPath $RepoRoot -Recurse -File -Filter '*.csproj' `
                    -ErrorAction SilentlyContinue |
                    Where-Object { $_.FullName -notmatch '[\\/](bin|obj)[\\/]' } |
                    Sort-Object FullName |
                    ForEach-Object { $_.FullName }
            )
        }
        else {
            $packTargets = $buildTargets
        }

        foreach ($proj in $packTargets) {
            $name = Split-Path -Leaf $proj
            Write-Host "  Packing: $name" -ForegroundColor DarkGray

            # Some projects (exe / sample apps) are not packable;
            # dotnet pack fails for them. Treat that as a warning.
            & dotnet pack "$proj" `
                -c $Configuration `
                --no-build `
                -o "$ArtifactsDir" `
                -v $verbosity

            if ($LASTEXITCODE -ne 0) {
                Write-Host "  WARNING: pack failed for $name (skipped)" `
                    -ForegroundColor DarkYellow
            }
        }

        $packages = @(
            Get-ChildItem -LiteralPath $ArtifactsDir -File -Filter '*.nupkg' `
                -ErrorAction SilentlyContinue
        )
        if ($packages.Count -gt 0) {
            Write-Host '  Produced package(s):' -ForegroundColor Green
            foreach ($pkg in $packages) {
                Write-Host "    - $($pkg.Name)" -ForegroundColor Green
            }
        }
        else {
            Write-Host '  WARNING: no .nupkg was produced.' -ForegroundColor DarkYellow
        }
    }

    'Test' {
        Write-Host '[3/3] Running tests...' -ForegroundColor Yellow

        # A project is treated as a test project when:
        #   - its leaf name contains "test" or "spec", or
        #   - its directory path contains a "test" or "tests" segment.
        #
        # In single-project mode we only consider that one project.
        if ($Project) {
            $allProjects = $buildTargets
        }
        else {
            $allProjects = @(
                Get-ChildItem -LiteralPath $RepoRoot -Recurse -File -Filter '*.csproj' `
                    -ErrorAction SilentlyContinue |
                    Where-Object { $_.FullName -notmatch '[\\/](bin|obj)[\\/]' } |
                    ForEach-Object { $_.FullName }
            )
        }

        $testProjects = @(
            $allProjects | Where-Object {
                $leaf = Split-Path -Leaf $_
                $dir  = Split-Path -Parent $_
                ($leaf -match '(?i)(test|spec)') -or
                ($dir  -match '(?i)[\\/](tests?)[\\/]')
            }
        )

        if ($testProjects.Count -eq 0) {
            Write-Host '  No test projects found.' -ForegroundColor DarkYellow
        }
        else {
            Write-Host "  Found $($testProjects.Count) test project(s)." -ForegroundColor DarkGray

            foreach ($proj in $testProjects) {
                $name = Split-Path -Leaf $proj
                Write-Host "  Testing: $name" -ForegroundColor DarkGray

                & dotnet test "$proj" `
                    -c $Configuration `
                    --no-restore `
                    -v $verbosity

                if ($LASTEXITCODE -ne 0) {
                    Write-Host "ERROR: tests failed for $name." -ForegroundColor Red
                    exit $LASTEXITCODE
                }
            }

            Write-Host '  All tests passed.' -ForegroundColor Green
        }
    }
}

# ---------------------------------------------------------------------------
# Done
# ---------------------------------------------------------------------------

Write-Host ''
Write-Host 'Build completed successfully.' -ForegroundColor Green
Write-Host ''