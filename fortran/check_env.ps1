<#
.SYNOPSIS
    Fortran development environment checker for Windows.

.DESCRIPTION
    Scans the local machine for everything needed to build, debug and edit
    Fortran code with VS Code.

.PARAMETER Quiet
    Suppress per-item detail blocks and print only the summary.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\check_env.ps1
    powershell -ExecutionPolicy Bypass -File .\check_env.ps1 -Quiet
#>

[CmdletBinding()]
param(
    [switch]$Quiet
)

# =====================================================================
#  Globals
# =====================================================================
$script:Results = New-Object System.Collections.ArrayList

function Add-Result {
    param(
        [string]$Category,
        [string]$Item,
        [string]$Status,
        [string]$Detail
    )
    [void]$script:Results.Add([PSCustomObject]@{
        Category = $Category
        Item     = $Item
        Status   = $Status
        Detail   = $Detail
    })
}

function Show-Section {
    param([string]$Title)
    if ($Quiet) { return }
    Write-Host ""
    Write-Host ("-" * 72) -ForegroundColor DarkGray
    Write-Host ("  " + $Title) -ForegroundColor Cyan
    Write-Host ("-" * 72) -ForegroundColor DarkGray
}

function Write-Line {
    param(
        [ValidateSet("OK", "WARN", "MISSING", "OPTIONAL", "INFO")]
        [string]$Status,
        [string]$Text
    )
    if ($Quiet) { return }

    $tag = switch ($Status) {
        "OK"       { "[ OK ]     " }
        "WARN"     { "[ WARN ]   " }
        "MISSING"  { "[ MISS ]   " }
        "OPTIONAL" { "[ SKIP ]   " }
        "INFO"     { "[ INFO ]   " }
    }
    $color = switch ($Status) {
        "OK"       { "Green" }
        "WARN"     { "Yellow" }
        "MISSING"  { "Red" }
        "OPTIONAL" { "DarkGray" }
        "INFO"     { "Gray" }
    }
    Write-Host ("  " + $tag + $Text) -ForegroundColor $color
}

function Write-Sub {
    param([string]$Text)
    if ($Quiet) { return }
    Write-Host ("               " + $Text) -ForegroundColor DarkGray
}

# Shorten a long string for display only (never used for logic)
function Format-Short {
    param([string]$Text, [int]$Max = 110)
    if (-not $Text) { return "" }
    if ($Text.Length -le $Max) { return $Text }
    return $Text.Substring(0, $Max - 3) + "..."
}

# =====================================================================
#  Generic tool probe
# =====================================================================
function Test-Tool {
    param(
        [string]$Category,
        [string]$Name,
        [string]$VersionArg = "--version",
        [switch]$Optional
    )

    $cmd = Get-Command $Name -ErrorAction SilentlyContinue | Select-Object -First 1

    if (-not $cmd) {
        if ($Optional) {
            Write-Line OPTIONAL ("{0,-12} not found (optional)" -f $Name)
            Add-Result $Category $Name "OPTIONAL" "not found in PATH"
        } else {
            Write-Line MISSING  ("{0,-12} not found in PATH" -f $Name)
            Add-Result $Category $Name "MISSING" "not found in PATH"
        }
        return $null
    }

    $detail = ""
    try {
        $raw = & $cmd.Source $VersionArg 2>&1 | Select-Object -First 1
        if ($raw) { $detail = ("$raw").Trim() }
    } catch {
        $detail = "version query failed"
    }

    Write-Line OK ("{0,-12} {1}" -f $Name, $detail)
    Write-Sub ("path: " + $cmd.Source)
    Add-Result $Category $Name "OK" ("$detail | " + $cmd.Source)
    return $cmd
}

# =====================================================================
#  Banner
# =====================================================================
Write-Host ""
Write-Host "==============================================================" -ForegroundColor Cyan
Write-Host "  Fortran Development Environment Check" -ForegroundColor Cyan
Write-Host "==============================================================" -ForegroundColor Cyan
Write-Host ("  Host   : {0}" -f $env:COMPUTERNAME)
Write-Host ("  User   : {0}" -f $env:USERNAME)
Write-Host ("  Date   : {0}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))
Write-Host ("  PS     : {0}" -f $PSVersionTable.PSVersion)
Write-Host ("  OS     : {0}" -f (Get-CimInstance Win32_OperatingSystem).Caption)

# =====================================================================
#  1. Fortran compilers
# =====================================================================
Show-Section "1. Fortran Compilers"

Test-Tool -Category "Compiler" -Name "gfortran" | Out-Null

$allGfortran = @(Get-Command gfortran -All -ErrorAction SilentlyContinue)
if ($allGfortran.Count -gt 1) {
    Write-Line WARN ("multiple gfortran executables found in PATH ({0}):" -f $allGfortran.Count)
    foreach ($g in $allGfortran) { Write-Sub $g.Source }
    Add-Result "Compiler" "gfortran (multiple)" "WARN" (($allGfortran | ForEach-Object { $_.Source }) -join "; ")
}

Test-Tool -Category "Compiler" -Name "ifx"   -VersionArg "--version" -Optional | Out-Null
Test-Tool -Category "Compiler" -Name "ifort" -VersionArg "--version" -Optional | Out-Null

# =====================================================================
#  2. Companion toolchain
# =====================================================================
Show-Section "2. Companion Build / Debug Toolchain"

Test-Tool -Category "Toolchain" -Name "gcc"  | Out-Null
Test-Tool -Category "Toolchain" -Name "g++"  | Out-Null
Test-Tool -Category "Toolchain" -Name "gdb"  | Out-Null

# Warn if make.exe is not GNU make (Borland/Embarcadero make is incompatible)
$makeCmd = Test-Tool -Category "Toolchain" -Name "make" -Optional
if ($makeCmd) {
    try {
        $makeVer = (& $makeCmd.Source --version 2>&1 | Out-String)
        if ($makeVer -notmatch "GNU Make") {
            Write-Line WARN "make is NOT GNU make (Makefiles may not work)"
            Write-Sub "detected: $(Format-Short ($makeVer.Trim().Split([Environment]::NewLine)[0]) 100)"
            Write-Sub "consider CMake, or install mingw32-make into D:\mingw64\bin"
            Add-Result "Toolchain" "make (non-GNU)" "WARN" "not GNU make; Makefiles may break"
        }
    } catch {}
}

Test-Tool -Category "Toolchain" -Name "cmake" -Optional | Out-Null
Test-Tool -Category "Toolchain" -Name "ninja" -Optional | Out-Null

# =====================================================================
#  3. Python + fortls
# =====================================================================
Show-Section "3. Python & Fortran Language Server (fortls)"

$pyCmd = Test-Tool -Category "Python" -Name "python" -VersionArg "--version"
Test-Tool -Category "Python" -Name "pip" -VersionArg "--version" | Out-Null

# Note about Python version compatibility for fortls
if ($pyCmd) {
    try {
        $pyVerRaw = (& $pyCmd.Source --version 2>&1 | Out-String).Trim()
        if ($pyVerRaw -match "Python\s+(\d+)\.(\d+)") {
            $maj = [int]$Matches[1]; $min = [int]$Matches[2]
            if ($maj -ge 3 -and $min -ge 14) {
                Write-Line WARN ("Python {0}.{1} is very new; fortls dependencies may not have wheels yet" -f $maj, $min)
                Add-Result "Python" "version" "WARN" ("Python $maj.$min may lack fortls-compatible wheels")
            }
        }
    } catch {}
}

$fortlsCmd = Get-Command fortls -ErrorAction SilentlyContinue | Select-Object -First 1

if ($fortlsCmd) {
    $v = ""
    try { $v = (& $fortlsCmd.Source --version 2>&1 | Select-Object -First 1).Trim() } catch {}
    Write-Line OK ("fortls       {0}" -f $v)
    Write-Sub ("path: " + $fortlsCmd.Source)
    Add-Result "fortls" "fortls" "OK" ("$v | " + $fortlsCmd.Source)
}
else {
    # fortls is often installed into a user/global Python Scripts dir but not on PATH
    $searchRoots = @(
        $env:APPDATA,
        (Join-Path $env:LOCALAPPDATA "Programs\Python"),
        "C:\Python314",
        "C:\Python313",
        "C:\Python312"
    ) | Where-Object { $_ -and (Test-Path $_) }

    $found = @()
    foreach ($root in $searchRoots) {
        $found += @(Get-ChildItem -Path $root -Recurse -Filter "fortls.exe" -ErrorAction SilentlyContinue -Depth 4)
    }

    if ($found.Count -gt 0) {
        Write-Line WARN "fortls installed but NOT on PATH:"
        foreach ($f in $found) { Write-Sub $f.FullName }
        Write-Sub "Add its folder to PATH, or set fortran.fortls.path in VS Code settings."
        Add-Result "fortls" "fortls" "WARN" ("installed but not in PATH: " + $found[0].FullName)
    }
    else {
        Write-Line MISSING "fortls not found (install with: pip install fortls)"
        Write-Sub "If pip fails on Python 3.14, try: pip install --upgrade pip"
        Write-Sub "If it still fails, install Python 3.12/3.13 and pip install fortls there."
        Add-Result "fortls" "fortls" "MISSING" "run: pip install fortls"
    }
}

# =====================================================================
#  4. Optional formatters
# =====================================================================
Show-Section "4. Formatters (optional)"

Test-Tool -Category "Formatter" -Name "fprettify" -Optional | Out-Null
Test-Tool -Category "Formatter" -Name "findent"   -Optional | Out-Null

# =====================================================================
#  5. VS Code + extensions
# =====================================================================
Show-Section "5. VS Code & Extensions"

$codePath = $null
$c = Get-Command code -ErrorAction SilentlyContinue | Select-Object -First 1
if ($c) {
    $codePath = $c.Source
}
else {
    $codeCandidates = @(
        (Join-Path $env:LOCALAPPDATA "Programs\Microsoft VS Code\bin\code.cmd"),
        "C:\Program Files\Microsoft VS Code\bin\code.cmd",
        "C:\Program Files (x86)\Microsoft VS Code\bin\code.cmd"
    )
    foreach ($p in $codeCandidates) {
        if (Test-Path $p) { $codePath = $p; break }
    }
}

if ($codePath) {
    $v = ""
    try { $v = (& $codePath --version 2>&1 | Select-Object -First 1).Trim() } catch {}
    Write-Line OK ("code         {0}" -f $v)
    Write-Sub ("path: " + $codePath)
    Add-Result "VSCode" "code" "OK" ("$v | " + $codePath)

    $extensions = [ordered]@{
        "ms-vscode.cpptools"           = @{ Name = "C/C++ (debug support)"; Group = "Debug"  }
        "fortran-lang.linter-gfortran" = @{ Name = "Modern Fortran";       Group = "Editor" }
    }

    $exts = @()
    try {
        # Guard against the CLI hanging (has been observed on some setups)
        $job = Start-Job -ScriptBlock {
            param($p)
            & $p --list-extensions 2>&1
        } -ArgumentList $codePath

        if (Wait-Job $job -Timeout 30) {
            $raw = Receive-Job $job
            $exts = @($raw | ForEach-Object { "$_".Trim() } | Where-Object { $_ -ne "" })
        } else {
            Write-Line WARN "listing VS Code extensions timed out (30s)"
            Add-Result "VSCode" "extensions" "WARN" "list-extensions timed out"
        }
        Remove-Job $job -Force -ErrorAction SilentlyContinue
    } catch {
        Write-Line WARN "failed to query installed VS Code extensions"
        Add-Result "VSCode" "extensions" "WARN" "list failed"
    }

    if ($exts.Count -gt 0) {
        foreach ($id in $extensions.Keys) {
            $meta = $extensions[$id]
            if ($exts -contains $id) {
                Write-Line OK ("extension    {0}  ({1})" -f $id, $meta.Name)
                Add-Result ("VSCode-" + $meta.Group) $id "OK" $meta.Name
            }
            else {
                Write-Line MISSING ("extension    {0}  ({1}) not installed" -f $id, $meta.Name)
                Add-Result ("VSCode-" + $meta.Group) $id "MISSING" ("code --install-extension " + $id)
            }
        }
    }
}
else {
    Write-Line MISSING "code CLI not found in PATH or default install locations"
    Add-Result "VSCode" "code" "MISSING" "VS Code CLI not found"
}

# =====================================================================
#  6. PATH sanity check
# =====================================================================
Show-Section "6. PATH Sanity Check"

$pathEntries = @($env:Path -split ";" | Where-Object { $_ -ne "" })
$relevant = @($pathEntries | Where-Object { $_ -match "msys|mingw|gcc|fortran|Python|VS Code|vscode" })

if ($relevant.Count -gt 0) {
    foreach ($r in $relevant) {
        Write-Line INFO (Format-Short $r 110)

        # Malformed entry: multiple drive prefixes glued together (no separator)
        # e.g. "...\noConfigScriptsC:\Users\...\noConfigScripts"
        $driveMatches = [regex]::Matches($r, '[A-Za-z]:[\\/]')
        if ($driveMatches.Count -gt 1) {
            Write-Line WARN ("  ^ malformed entry: {0} drive prefixes without separators" -f $driveMatches.Count)
            Write-Sub "This usually means an installer wrote PATH without a ';'."
            Write-Sub "Fix it via System Properties -> Environment Variables -> Path."
            Add-Result "PATH" "malformed entry" "WARN" ("$($driveMatches.Count) drive prefixes glued: " + (Format-Short $r 80))
        }
    }
}
else {
    Write-Line WARN "no compiler / Python related entries detected in PATH"
}

# Duplicate entries (very common source of 'wrong compiler' bugs)
$dupes = @($pathEntries | Group-Object | Where-Object { $_.Count -gt 1 })
if ($dupes.Count -gt 0) {
    Write-Line WARN ("PATH contains {0} duplicated entries" -f $dupes.Count)
    if (-not $Quiet) {
        foreach ($d in $dupes) {
            Write-Sub ("x{0}  {1}" -f $d.Count, (Format-Short $d.Name 100))
        }
    }
    Add-Result "PATH" "duplicates" "WARN" ("$($dupes.Count) duplicated PATH entries")
}

# =====================================================================
#  7. Compile & run smoke test
# =====================================================================
Show-Section "7. Smoke Test (compile + run)"

$gfortran = Get-Command gfortran -ErrorAction SilentlyContinue | Select-Object -First 1

if (-not $gfortran) {
    Write-Line MISSING "gfortran unavailable - smoke test skipped"
    Add-Result "SmokeTest" "gfortran" "MISSING" "skipped"
}
else {
    $tmp = Join-Path $env:TEMP ("fortran_smoke_" + [guid]::NewGuid().ToString("N").Substring(0, 8))
    New-Item -ItemType Directory -Path $tmp -Force | Out-Null

    try {
        $src = Join-Path $tmp "hello.f90"
        $exe = Join-Path $tmp "hello.exe"

        @"
program hello
    implicit none
    print *, "hello from fortran"
end program hello
"@ | Set-Content -Path $src -Encoding ASCII

        $compileOut = & $gfortran.Source $src -o $exe 2>&1
        if ($LASTEXITCODE -eq 0 -and (Test-Path $exe)) {
            $runOut = (& $exe 2>&1) -join " "
            Write-Line OK ("compile OK  ->  output: {0}" -f $runOut.Trim())
            Add-Result "SmokeTest" "compile+run" "OK" $runOut.Trim()
        }
        else {
            Write-Line MISSING "compilation failed"
            Write-Sub (($compileOut | Out-String).Trim())
            Add-Result "SmokeTest" "compile" "MISSING" (($compileOut | Out-String).Trim())
        }
    }
    catch {
        Write-Line WARN ("smoke test error: {0}" -f $_.Exception.Message)
        Add-Result "SmokeTest" "compile+run" "WARN" $_.Exception.Message
    }
    finally {
        Remove-Item -Path $tmp -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# =====================================================================
#  Summary
# =====================================================================
Show-Section "Summary"

$ok       = @($script:Results | Where-Object { $_.Status -eq "OK"       }).Count
$warn     = @($script:Results | Where-Object { $_.Status -eq "WARN"     }).Count
$miss     = @($script:Results | Where-Object { $_.Status -eq "MISSING"  }).Count
$opt      = @($script:Results | Where-Object { $_.Status -eq "OPTIONAL" }).Count

Write-Host ("  OK        : {0}" -f $ok)   -ForegroundColor Green
Write-Host ("  Warning   : {0}" -f $warn) -ForegroundColor Yellow
Write-Host ("  Missing   : {0}" -f $miss) -ForegroundColor Red
Write-Host ("  Optional  : {0}" -f $opt)  -ForegroundColor DarkGray

# Split missing items by importance
$debugMissing  = @($script:Results | Where-Object { $_.Status -eq "MISSING" -and $_.Category -eq "VSCode-Debug" })
$editorMissing = @($script:Results | Where-Object { $_.Status -eq "MISSING" -and $_.Category -eq "VSCode-Editor" })
$coreMissing   = @($script:Results | Where-Object { $_.Status -eq "MISSING" -and $_.Category -notlike "VSCode-*" })

if ($coreMissing.Count -gt 0) {
    Write-Host ""
    Write-Host "  Missing (core - needed to build/run):" -ForegroundColor Red
    $coreMissing | ForEach-Object {
        Write-Host ("    - {0,-28} {1}" -f $_.Item, $_.Detail) -ForegroundColor Red
    }
}
if ($debugMissing.Count -gt 0) {
    Write-Host ""
    Write-Host "  Missing (debug - needed for breakpoints):" -ForegroundColor Red
    $debugMissing | ForEach-Object {
        Write-Host ("    - {0,-28} {1}" -f $_.Item, $_.Detail) -ForegroundColor Red
    }
}
if ($editorMissing.Count -gt 0) {
    Write-Host ""
    Write-Host "  Missing (editor - nice to have):" -ForegroundColor Yellow
    $editorMissing | ForEach-Object {
        Write-Host ("    - {0,-28} {1}" -f $_.Item, $_.Detail) -ForegroundColor Yellow
    }
}

if ($warn -gt 0) {
    Write-Host ""
    Write-Host "  Warnings:" -ForegroundColor Yellow
    $script:Results | Where-Object { $_.Status -eq "WARN" } | ForEach-Object {
        Write-Host ("    - {0,-28} {1}" -f $_.Item, (Format-Short $_.Detail 80)) -ForegroundColor Yellow
    }
}

Write-Host ""
Write-Host "--------------------------------------------------------------" -ForegroundColor DarkGray
Write-Host "  Quick fixes:" -ForegroundColor Cyan
Write-Host "    fortls    : pip install fortls"
Write-Host "    extensions: code --install-extension fortran-lang.linter-gfortran"
Write-Host "                code --install-extension ms-vscode.cpptools"
Write-Host "--------------------------------------------------------------" -ForegroundColor DarkGray

if ($coreMissing.Count -gt 0) { exit 2 }
elseif ($miss -gt 0)          { exit 1 }
else                          { exit 0 }