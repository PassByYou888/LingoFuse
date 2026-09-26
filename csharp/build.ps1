<#
.SYNOPSIS
    Builds every C# project in the LingoFuse C# binding.

.DESCRIPTION
    Recursively scans the repository for every C# project (*.csproj) and
    runs `dotnet restore` and `dotnet build` on each one. The solution
    file is not required: any project layout is supported, and new
    projects are picked up automatically.

    Optionally packs NuGet packages, runs test projects, and cleans
    before building.

.PARAMETER Configuration
    Build configuration. Accepts Debug (default) or Release.

.PARAMETER Target
    What to do after building:

      Build  (default)  Restore + build every project.
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
    Debug build of every project in the repository.

.EXAMPLE
    .\build.ps1 -Configuration Release -Target Pack
    Release build + NuGet packages in artifacts/.

.EXAMPLE
    .\build.ps1 -Clean -Target Test
    Clean, then build and run every test project.

.EXAMPLE
    .\build.ps1 -Project .\src\LingoFuse\LingoFuse.csproj
    Build only the LingoFuse library.

.EXAMPLE
    .\build.ps1 -Verbose
    Prints each project as it is processed.
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

# ---------------------------------------------------------------------------
# Header
# ---------------------------------------------------------------------------

Write-Host ''
Write-Host '=== LingoFuse C# binding - build ===' -ForegroundColor Cyan
Write-Host "Repository root : $RepoRoot"
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
# Discover projects
# ---------------------------------------------------------------------------

if ($Project) {
    # Single-project mode.
    $resolved = Resolve-Path -LiteralPath $Project -ErrorAction SilentlyContinue
    if (-not $resolved) {
        Write-Host "ERROR: project file not found: $Project" -ForegroundColor Red
        exit 1
    }
    $projects = @($resolved.Path)
    Write-Host "Single-project mode: $(Split-Path -Leaf $projects[0])" -ForegroundColor DarkGray
} else {
    # Discover every *.csproj under the repository root, excluding bin/obj.
    $projects = @(
        Get-ChildItem -LiteralPath $RepoRoot -Recurse -File -Filter '*.csproj' `
            -ErrorAction SilentlyContinue |
            Where-Object { $_.FullName -notmatch '[\\/](bin|obj)[\\/]' } |
            Sort-Object FullName |
            ForEach-Object { $_.FullName }
    )

    if ($projects.Count -eq 0) {
        Write-Host 'ERROR: no .csproj files found under the repository root.' -ForegroundColor Red
        exit 1
    }

    Write-Host "Found $($projects.Count) project(s):" -ForegroundColor DarkGray
    foreach ($proj in $projects) {
        $rel = $proj.Substring($RepoRoot.Length).TrimStart('\', '/')
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
        & $cleanScript -Configuration $Configuration
        if ($LASTEXITCODE -ne 0) {
            Write-Host 'ERROR: clean.ps1 reported a failure.' -ForegroundColor Red
            exit $LASTEXITCODE
        }
    } else {
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

    foreach ($proj in $projects) {
        $name = Split-Path -Leaf $proj
        Write-Host "  Restoring: $name" -ForegroundColor DarkGray

        & dotnet restore "$proj"
        if ($LASTEXITCODE -ne 0) {
            Write-Host "ERROR: dotnet restore failed for $name" -ForegroundColor Red
            exit $LASTEXITCODE
        }
    }

    Write-Host '  Restore completed.' -ForegroundColor Green
} else {
    Write-Host '[1/3] Skipping restore (-NoRestore).' -ForegroundColor DarkGray
}

# ---------------------------------------------------------------------------
# Step 2: build
# ---------------------------------------------------------------------------

Write-Host '[2/3] Building...' -ForegroundColor Yellow

foreach ($proj in $projects) {
    $name = Split-Path -Leaf $proj
    Write-Host "  Building: $name" -ForegroundColor DarkGray

    & dotnet build "$proj" `
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

        foreach ($proj in $projects) {
            $name = Split-Path -Leaf $proj
            Write-Host "  Packing: $name" -ForegroundColor DarkGray

            # Some projects (test executables, sample apps) are not
            # packable. dotnet pack fails for them; treat that as a
            # warning and continue.
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
        } else {
            Write-Host '  WARNING: no .nupkg was produced.' -ForegroundColor DarkYellow
        }
    }

    'Test' {
        Write-Host '[3/3] Running tests...' -ForegroundColor Yellow

        # A project is treated as a test project when:
        #   - its leaf name contains "test" or "spec", or
        #   - its directory path contains a "test" or "tests" segment.
        $testProjects = @(
            $projects |
                Where-Object {
                    $leaf = Split-Path -Leaf $_
                    $dir  = Split-Path -Parent $_
                    ($leaf -match '(?i)(test|spec)') -or
                    ($dir  -match '(?i)[\\/](tests?)[\\/]')
                }
        )

        if ($testProjects.Count -eq 0) {
            Write-Host '  No test projects found.' -ForegroundColor DarkYellow
            exit 0
        }

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

# ---------------------------------------------------------------------------
# Done
# ---------------------------------------------------------------------------

Write-Host ''
Write-Host 'Build completed successfully.' -ForegroundColor Green
Write-Host ''