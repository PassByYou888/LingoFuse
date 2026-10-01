#Requires -Version 5.1
<#
.SYNOPSIS
    Publish every executable C# project in the LingoFuse C# binding.

.DESCRIPTION
    Scans every *.csproj under the script directory, keeps those whose
    <OutputType> is Exe or WinExe, and runs `dotnet publish` for each
    of them. Output goes to .\publish\<ProjectName>\.

    Executable projects are discovered dynamically, so adding a new
    tool project, renaming an existing one, or moving the library
    project does not require editing this script.

    The library project (src/LingoFuse_cs/LingoFuse_cs.csproj) is
    referenced by every executable project and is copied into their
    output folders as part of the build. It is therefore never
    published on its own.

    Layout this script expects (documentation only; discovery is
    layout-independent):

        lf_csharp.sln
        CrossCall/CrossCall.csproj               (Exe)
        CrossNode/CrossNode.csproj               (Exe)
        crossService/crossService.csproj         (Exe)
        src/LingoFuse_cs/LingoFuse_cs.csproj     (Library, skipped)
        test/test.csproj                         (Exe)

.PARAMETER Configuration
    Build configuration. Default: Release.

.PARAMETER Runtime
    Target runtime identifier. Default: win-x64.

.PARAMETER SelfContained
    Bundle the .NET runtime into the output. Bigger, but no runtime
    install required on the target machine. Default is framework-
    dependent.

.PARAMETER SingleFile
    Bundle each project into a single .exe. Implies native library
    self-extraction on first run.

.PARAMETER Clean
    Run clean.ps1 before publishing.

.PARAMETER Project
    Optional. When set, publish only the specified .csproj, provided
    it is an executable project. Accepts an absolute path or a path
    relative to the current working directory.

.EXAMPLE
    .\publish.ps1
    Framework-dependent Release build for win-x64.

.EXAMPLE
    .\publish.ps1 -SelfContained -SingleFile
    Self-contained single-file .exe per project.

.EXAMPLE
    .\publish.ps1 -Clean -SelfContained
    Clean, then publish self-contained, multi-file output.

.EXAMPLE
    .\publish.ps1 -Project .\CrossNode\CrossNode.csproj
    Publish only the CrossNode tool.
#>
[CmdletBinding()]
param(
    [string]$Configuration = 'Release',
    [string]$Runtime       = 'win-x64',
    [switch]$SelfContained,
    [switch]$SingleFile,
    [switch]$Clean,
    [string]$Project
)

$ErrorActionPreference = 'Stop'

# -------------------------------------------------------------------------
# Setup
# -------------------------------------------------------------------------
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
Set-Location -LiteralPath $scriptDir

$outRoot = Join-Path $scriptDir 'publish'

function Write-Info { param([string]$m) Write-Host "[publish] $m" -ForegroundColor Cyan   }
function Write-Ok   { param([string]$m) Write-Host "[publish] $m" -ForegroundColor Green  }
function Write-Warn { param([string]$m) Write-Host "[publish] $m" -ForegroundColor Yellow }
function Write-Fail { param([string]$m) Write-Host "[publish] $m" -ForegroundColor Red    }

# -------------------------------------------------------------------------
# Discover executable projects
# -------------------------------------------------------------------------
#
# A project is publishable when its <OutputType> is Exe or WinExe.
# SDK-style projects without an explicit <OutputType> default to
# Library and are skipped automatically; this is how the LingoFuse_cs
# binding library is excluded without hard-coding its name.

function Test-IsExecutableProject {
    param([Parameter(Mandatory)] [string]$CsprojPath)

    try {
        $content = Get-Content -LiteralPath $CsprojPath -Raw -ErrorAction Stop
        return [bool]($content -match '<OutputType>\s*(Exe|WinExe)\s*</OutputType>')
    }
    catch {
        return $false
    }
}

$projects = @()

if ($Project) {
    # ---- Single-project mode -------------------------------------------
    $resolved = Resolve-Path -LiteralPath $Project -ErrorAction SilentlyContinue
    if (-not $resolved) {
        Write-Fail "Project file not found: $Project"
        exit 1
    }
    $csprojPath = $resolved.Path

    if (-not (Test-IsExecutableProject $csprojPath)) {
        Write-Fail "Not an executable project (OutputType is not Exe/WinExe):"
        Write-Fail "  $csprojPath"
        exit 1
    }

    $projects = @(
        @{
            Name   = (Split-Path -Parent $csprojPath | Split-Path -Leaf)
            Csproj = $csprojPath
        }
    )
    Write-Info "Single-project mode: $($projects[0].Name)"
}
else {
    # ---- Full scan mode -------------------------------------------------
    $allProjects = @(
        Get-ChildItem -LiteralPath $scriptDir -Recurse -File -Filter '*.csproj' `
            -ErrorAction SilentlyContinue |
            Where-Object { $_.FullName -notmatch '[\\/](bin|obj)[\\/]' } |
            Sort-Object FullName
    )

    $projects = @(
        $allProjects |
            Where-Object { Test-IsExecutableProject $_.FullName } |
            ForEach-Object {
                @{
                    Name   = $_.Directory.Name
                    Csproj = $_.FullName
                }
            }
    )
}

# -------------------------------------------------------------------------
# Optional: run clean.ps1 first
# -------------------------------------------------------------------------
if ($Clean) {
    $cleanScript = Join-Path $scriptDir 'clean.ps1'
    if (Test-Path -LiteralPath $cleanScript -PathType Leaf) {
        Write-Info 'Running clean.ps1'
        & $cleanScript
    }
    else {
        Write-Warn 'clean.ps1 not found, skipping clean'
    }
}

# -------------------------------------------------------------------------
# Reset previous publish output
# -------------------------------------------------------------------------
if (Test-Path -LiteralPath $outRoot) {
    Write-Info "Removing previous publish output: $outRoot"
    Remove-Item -LiteralPath $outRoot -Recurse -Force
}
New-Item -ItemType Directory -Path $outRoot -Force | Out-Null

# -------------------------------------------------------------------------
# Pre-flight: nothing to do?
# -------------------------------------------------------------------------
if ($projects.Count -eq 0) {
    Write-Fail 'No executable project found under the script directory.'
    Write-Fail 'A project is considered executable when its .csproj declares'
    Write-Fail '<OutputType>Exe</OutputType> or <OutputType>WinExe</OutputType>.'
    exit 1
}

Write-Info ("Discovered {0} executable project(s):" -f $projects.Count)
foreach ($p in $projects) {
    $rel = $p.Csproj.Substring($scriptDir.Length).TrimStart('\', '/')
    Write-Info ("  - {0}  ({1})" -f $p.Name, $rel)
}

# -------------------------------------------------------------------------
# Build the shared dotnet publish argument list
# -------------------------------------------------------------------------
$publishArgs = @(
    'publish'
    '-c', $Configuration
    '-r', $Runtime
    '-p:PublishReadyToRun=false'
    '-p:PublishTrimmed=false'
)

if ($SelfContained) {
    $publishArgs += '--self-contained', 'true'
}
else {
    $publishArgs += '--self-contained', 'false'
}

if ($SingleFile) {
    $publishArgs += '-p:PublishSingleFile=true'
    $publishArgs += '-p:IncludeNativeLibrariesForSelfExtract=true'
    $publishArgs += '-p:DebugType=None'
    $publishArgs += '-p:DebugSymbols=false'
}

# -------------------------------------------------------------------------
# Publish each project
# -------------------------------------------------------------------------
$total    = $projects.Count
$index    = 0
$failures = @()
$sw       = [System.Diagnostics.Stopwatch]::StartNew()

foreach ($p in $projects) {
    $index++
    $projPath = $p.Csproj
    $outDir   = Join-Path $outRoot $p.Name

    Write-Host ''
    Write-Host ('=== [{0}/{1}] {2} ===' -f $index, $total, $p.Name) -ForegroundColor Cyan

    if (-not (Test-Path -LiteralPath $projPath -PathType Leaf)) {
        Write-Warn "SKIP: project file not found - $projPath"
        $failures += $p.Name
        continue
    }

    $itemSw = [System.Diagnostics.Stopwatch]::StartNew()

    # Run from the project folder so relative paths inside the csproj
    # (content files, Directory.Build.props, etc.) resolve correctly.
    Push-Location -LiteralPath (Split-Path -Parent $projPath)
    try {
        & dotnet @publishArgs -o $outDir $projPath
    }
    finally {
        Pop-Location
    }

    $code = $LASTEXITCODE
    $itemSw.Stop()
    $secs = '{0:N1}' -f $itemSw.Elapsed.TotalSeconds

    if ($code -ne 0) {
        Write-Fail ('FAIL: {0} (exit={1}, {2}s)' -f $p.Name, $code, $secs)
        $failures += $p.Name
        continue
    }

    # Report every .exe that was produced.
    $exes = @(Get-ChildItem -LiteralPath $outDir -Filter *.exe -File -ErrorAction SilentlyContinue)
    if ($exes.Count -gt 0) {
        foreach ($exe in $exes) {
            $sizeMB = '{0:N1}' -f ($exe.Length / 1MB)
            Write-Ok ('OK:   {0} -> {1} ({2} MB, {3}s)' -f $p.Name, $exe.Name, $sizeMB, $secs)
        }
    }
    else {
        Write-Warn ('WARN: {0} published but no .exe found (is OutputType=Exe?)' -f $p.Name)
    }
}

$sw.Stop()
$totalSecs = '{0:N1}' -f $sw.Elapsed.TotalSeconds

# -------------------------------------------------------------------------
# Summary
# -------------------------------------------------------------------------
Write-Host ''
if ($failures.Count -eq 0) {
    Write-Ok ('All projects published in {0}s. Output root: {1}' -f $totalSecs, $outRoot)
}
else {
    Write-Fail ('Finished with {0} failure(s) in {1}s: {2}' -f $failures.Count, $totalSecs, ($failures -join ', '))
    exit 1
}