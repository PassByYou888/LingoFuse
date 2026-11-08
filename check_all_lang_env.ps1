[CmdletBinding()]
param([switch]$Json)

$ErrorActionPreference = 'SilentlyContinue'
$env:DOTNET_CLI_UI_LANGUAGE = 'en'
$env:DOTNET_NOLOGO = '1'
$env:NO_COLOR = '1'
$env:NPM_CONFIG_UPDATE_NOTIFIER = 'false'

$script:OEMEncoding = $null
try {
    $script:OEMEncoding = [System.Text.Encoding]::GetEncoding([System.Globalization.CultureInfo]::CurrentCulture.TextInfo.OEMCodePage)
} catch {
    $script:OEMEncoding = [System.Text.Encoding]::UTF8
}
$script:TempDir = [System.IO.Path]::GetTempPath()
$script:ErlOtp = $null

function New-Check {
    param(
        [string]$Name, [string]$Status, [string]$Version = '',
        [string]$Category = '', [string]$Path = '', [string]$Note = ''
    )
    [pscustomobject]@{ Name = $Name; Status = $Status; Version = $Version; Category = $Category; Path = $Path; Note = $Note }
}

function Decode-Bytes {
    param([byte[]]$Bytes)
    if (-not $Bytes -or $Bytes.Length -eq 0) { return '' }
    try { $utf8 = [System.Text.Encoding]::UTF8.GetString($Bytes) } catch { $utf8 = '' }
    if ($utf8 -and $utf8.IndexOf([char]0xFFFD) -ge 0) {
        try { return $script:OEMEncoding.GetString($Bytes) } catch { return $utf8 }
    }
    return $utf8.TrimStart([char]0xFEFF)
}

function Format-CmdArgs {
    param([string[]]$Arguments)
    if (-not $Arguments -or $Arguments.Count -eq 0) { return '' }
    $parts = foreach ($a in $Arguments) {
        $s = [string]$a
        if ($s -match '[\s"&|<>^]') { '"' + ($s -replace '"', '\"') + '"' } else { $s }
    }
    return ($parts -join ' ')
}

function Invoke-NativeCapture {
    param([string]$Exe, [string[]]$Arguments = @(), [int]$TimeoutMs = 20000, [string]$WorkingDirectory)
    $isBatch = $Exe -match '\.(cmd|bat)$'
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true
    $psi.WorkingDirectory = if ($WorkingDirectory) { $WorkingDirectory } else { $script:TempDir }
    if ($isBatch) {
        $psi.FileName = 'cmd.exe'
        $argStr = ''
        if ($Arguments -and $Arguments.Count -gt 0) { $argStr = ' ' + (Format-CmdArgs $Arguments) }
        $psi.Arguments = "/d /s /c `"`"$Exe`"$argStr`""
    } else {
        $psi.FileName = $Exe
        if ($Arguments) { $psi.Arguments = Format-CmdArgs $Arguments }
    }
    try {
        $p = [System.Diagnostics.Process]::Start($psi)
        if (-not $p) { return $null }
        $stdoutStream = New-Object System.IO.MemoryStream
        $stderrStream = New-Object System.IO.MemoryStream
        $outTask = $p.StandardOutput.BaseStream.CopyToAsync($stdoutStream)
        $errTask = $p.StandardError.BaseStream.CopyToAsync($stderrStream)
        if (-not $p.WaitForExit($TimeoutMs)) {
            try { $p.Kill() } catch {}
            return [pscustomobject]@{ Stdout = ''; Stderr = ''; ExitCode = -1; TimedOut = $true }
        }
        $null = $outTask.Wait(2000)
        $null = $errTask.Wait(2000)
        return [pscustomobject]@{
            Stdout   = Decode-Bytes $stdoutStream.ToArray()
            Stderr   = Decode-Bytes $stderrStream.ToArray()
            ExitCode = $p.ExitCode
            TimedOut = $false
        }
    } catch {
        return $null
    }
}

function Get-ExecutableInfo {
    param([string]$Name, [string]$Fallback)
    $cmd = Get-Command $Name -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $cmd -and $Fallback) {
        $cmd = Get-Command $Fallback -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    }
    if ($cmd) {
        $path = if ($cmd.Path) { $cmd.Path } else { $cmd.Source }
        $isStoreAlias = $false
        if ($path -and ($path -like '*\WindowsApps\*')) { $isStoreAlias = $true }
        return [pscustomobject]@{ Path = $path; IsStoreAlias = $isStoreAlias }
    }
    $where = & where.exe $Name 2>$null
    if ($where) {
        $first = ($where -split "`r?`n" | Where-Object { $_ -and (Test-Path $_) } | Select-Object -First 1)
        if ($first) { return [pscustomobject]@{ Path = $first; IsStoreAlias = $false } }
    }
    return $null
}

function Get-FirstNonEmptyLine {
    param([string]$Text)
    if (-not $Text) { return $null }
    foreach ($ln in ($Text -split "`r?`n")) {
        if (-not $ln) { continue }
        $trimmed = $ln.Trim()
        if (-not $trimmed) { continue }
        $stripped = $trimmed -replace "`e\[[0-9;]*[A-Za-z]", ''
        if (-not $stripped) { continue }
        $hasPrintable = $false
        foreach ($ch in $stripped.ToCharArray()) {
            if (-not [char]::IsControl($ch)) { $hasPrintable = $true; break }
        }
        if ($hasPrintable) { return $stripped.Trim() }
    }
    return $null
}

function Get-ShortSummary {
    param([string]$Text, [int]$MaxLen = 200)
    if (-not $Text) { return '' }
    $collapsed = $Text -replace '\s+', ' '
    $collapsed = $collapsed.Trim()
    if (-not $collapsed) { return '' }
    if ($collapsed.Length -gt $MaxLen) { return $collapsed.Substring(0, $MaxLen) + '...' }
    return $collapsed
}

function Resolve-VersionOrFallback {
    param([string]$RawVer, [int]$ExitCode)
    $clean = if ($RawVer) { $RawVer.Trim() } else { '' }
    if ($clean.Length -gt 0) { return @{ Ok = $true; Ver = $clean } }
    if ($ExitCode -eq 0) { return @{ Ok = $true; Ver = '(no output)' } }
    return @{ Ok = $false; Ver = "(exit $ExitCode)" }
}

function Get-ToolVersion {
    param(
        [string]$Name,
        [string]$Exe,
        [string[]]$Arguments = @('--version'),
        [string]$Fallback,
        [string]$Category = 'Language & Toolchain',
        [scriptblock]$VersionParser,
        [int]$TimeoutMs = 20000
    )
    $info = Get-ExecutableInfo -Name $Exe -Fallback $Fallback
    if (-not $info) { return New-Check -Name $Name -Status 'MISSING' -Category $Category }
    if ($info.IsStoreAlias) {
        return New-Check -Name $Name -Status 'STORE-ALIAS' -Version '(store stub)' -Category $Category -Path $info.Path
    }
    $res = Invoke-NativeCapture -Exe $info.Path -Arguments $Arguments -TimeoutMs $TimeoutMs
    if (-not $res) { return New-Check -Name $Name -Status 'FAILED' -Version '(cannot execute)' -Category $Category -Path $info.Path }
    if ($res.TimedOut) { return New-Check -Name $Name -Status 'TIMEOUT' -Version "(>${TimeoutMs}ms)" -Category $Category -Path $info.Path }
    $combined = "$($res.Stdout)`n$($res.Stderr)"
    $ver = $null
    if ($VersionParser) { $ver = & $VersionParser $combined }
    if (-not $ver -or ($ver -and $ver.Trim().Length -eq 0)) { $ver = Get-FirstNonEmptyLine $combined }
    $resolved = Resolve-VersionOrFallback -RawVer $ver -ExitCode $res.ExitCode
    if ($resolved.Ok) {
        return New-Check -Name $Name -Status 'OK' -Version $resolved.Ver -Category $Category -Path $info.Path
    } else {
        $note = Get-ShortSummary -Text $res.Stderr -MaxLen 200
        return New-Check -Name $Name -Status 'FAILED' -Version $resolved.Ver -Category $Category -Path $info.Path -Note $note
    }
}

function Get-FirstExistingPath {
    param([string[]]$Candidates)
    foreach ($c in $Candidates) {
        if ($c -and (Test-Path $c)) { return $c }
    }
    return $null
}

function Get-VcpkgInfo {
    $info = Get-ExecutableInfo -Name 'vcpkg'
    $path = $null
    if ($info -and -not $info.IsStoreAlias) {
        $path = $info.Path
    } else {
        $root = Get-FirstExistingPath @($env:VCPKG_ROOT, 'C:\vcpkg', 'C:\dev\vcpkg', 'C:\src\vcpkg')
        if ($root) {
            $exe = Join-Path $root 'vcpkg.exe'
            if (Test-Path $exe) { $path = $exe }
        }
    }
    if (-not $path) { return New-Check -Name 'vcpkg' -Status 'MISSING' -Category 'Package Manager' }
    $res = Invoke-NativeCapture -Exe $path -Arguments @('version')
    $combined = if ($res) { "$($res.Stdout)`n$($res.Stderr)" } else { '' }
    $ver = $null
    if ($combined -match 'version\s+(\d{4}[-.]\d{2}[-.]\d{2}[-\w]*)') { $ver = $matches[1] }
    elseif ($combined -match 'version\s+([\w.-]+)') { $ver = $matches[1] }
    if (-not $ver) { $ver = 'detected' }
    return New-Check -Name 'vcpkg' -Status 'OK' -Version $ver -Category 'Package Manager' -Path $path
}

function Get-Msys2Info {
    $candidates = New-Object System.Collections.ArrayList
    if ($env:MSYS2_ROOT) { [void]$candidates.Add(@{ Root = $env:MSYS2_ROOT; Source = 'standalone' }) }
    foreach ($p in @('C:\msys64', 'D:\msys64', 'C:\msys2', 'D:\msys2')) {
        if (Test-Path $p) { [void]$candidates.Add(@{ Root = $p; Source = 'standalone' }) }
    }
    $ruby = Get-ExecutableInfo -Name 'ruby'
    if ($ruby -and -not $ruby.IsStoreAlias) {
        $rubyRoot = Split-Path (Split-Path $ruby.Path -Parent) -Parent
        $rubyMsys = Join-Path $rubyRoot 'msys64'
        if (Test-Path (Join-Path $rubyMsys 'usr\bin')) {
            [void]$candidates.Add(@{ Root = $rubyMsys; Source = 'ruby-bundled' })
        }
    }
    $git = Get-ExecutableInfo -Name 'git'
    if ($git -and -not $git.IsStoreAlias) {
        $gitRoot = Split-Path (Split-Path $git.Path -Parent) -Parent
        $gitUsrBin = Join-Path $gitRoot 'usr\bin'
        if (Test-Path $gitUsrBin) {
            [void]$candidates.Add(@{ Root = $gitRoot; Source = 'git-bundled' })
        }
    }
    $results = @()
    if ($candidates.Count -eq 0) {
        $results += New-Check -Name 'MSYS2 (standalone)' -Status 'MISSING' -Category 'Toolchain Infrastructure'
    } else {
        foreach ($c in $candidates) {
            $usrBin = Join-Path $c.Root 'usr\bin'
            $pacman = Join-Path $usrBin 'pacman.exe'
            $hasPacman = Test-Path $pacman
            $ver = ''
            if ($hasPacman) {
                $res = Invoke-NativeCapture -Exe $pacman -Arguments @('--version')
                $line = Get-FirstNonEmptyLine $res.Stdout
                if ($line -match 'Pacman v([\d.]+)') { $ver = "pacman $($matches[1])" }
            }
            if (-not $ver) {
                $ver = if ($hasPacman) { 'detected' } else { 'partial (no pacman)' }
            }
            $displayName = switch ($c.Source) {
                'standalone'   { 'MSYS2 (standalone)' }
                'ruby-bundled' { 'MSYS2 (ruby-bundled)' }
                'git-bundled'  { 'MSYS2 (git-bundled, partial)' }
                default        { "MSYS2 ($($c.Source))" }
            }
            $results += New-Check -Name $displayName -Status 'OK' -Version $ver -Category 'Toolchain Infrastructure' -Path $usrBin
        }
    }
    if ($env:MSYSTEM) {
        $results += New-Check -Name 'MSYSTEM' -Status 'OK' -Version $env:MSYSTEM -Category 'Toolchain Infrastructure' -Path 'env:MSYSTEM'
    } else {
        $results += New-Check -Name 'MSYSTEM' -Status 'MISSING' -Category 'Toolchain Infrastructure'
    }
    return $results
}

function Get-DelphiInfo {
    $found = @(); $foundPaths = @()
    foreach ($root in @('HKLM:\SOFTWARE\WOW6432Node\Embarcadero\BDS', 'HKLM:\SOFTWARE\Embarcadero\BDS')) {
        if (-not (Test-Path $root)) { continue }
        Get-ChildItem $root -ErrorAction SilentlyContinue | ForEach-Object {
            $props = Get-ItemProperty $_.PSPath -ErrorAction SilentlyContinue
            if ($props.ProductName -match 'Delphi') {
                $found += "$($_.PSChildName) ($($props.ProductName))"
                if ($props.RootDir) { $foundPaths += $props.RootDir }
            }
        }
    }
    if ($found) { return New-Check -Name 'Delphi' -Status 'OK' -Version ($found -join '; ') -Category 'Language & Toolchain' -Path ($foundPaths -join '; ') }
    return New-Check -Name 'Delphi' -Status 'MISSING' -Category 'Language & Toolchain'
}

function Get-GoEnvInfo {
    $info = Get-ExecutableInfo -Name 'go'
    if (-not $info -or $info.IsStoreAlias) { return New-Check -Name 'go env' -Status 'MISSING' -Category 'Language & Toolchain' }
    $res = Invoke-NativeCapture -Exe $info.Path -Arguments @('env', '-json')
    if (-not $res -or -not $res.Stdout) {
        return New-Check -Name 'go env' -Status 'FAILED' -Version '(execution failed)' -Category 'Language & Toolchain' -Path $info.Path
    }
    try { $json = $res.Stdout | ConvertFrom-Json } catch {
        return New-Check -Name 'go env' -Status 'FAILED' -Version '(parse failed)' -Category 'Language & Toolchain' -Path $info.Path
    }
    $parts = @()
    foreach ($k in @('GOOS','GOARCH','CGO_ENABLED','GOROOT','GOPATH','GOPROXY')) {
        $v = $json.$k
        if ($v) { $parts += "$k=$v" }
    }
    return New-Check -Name 'go env' -Status 'OK' -Version ($parts -join '; ') -Category 'Language & Toolchain' -Path $info.Path
}

function Get-DotnetWorkloads {
    $info = Get-ExecutableInfo -Name 'dotnet'
    if (-not $info -or $info.IsStoreAlias) { return New-Check -Name 'dotnet workload' -Status 'MISSING' -Category 'Language & Toolchain' }
    $res = Invoke-NativeCapture -Exe $info.Path -Arguments @('workload', 'list')
    if (-not $res) { return New-Check -Name 'dotnet workload' -Status 'FAILED' -Version '(execution failed)' -Category 'Language & Toolchain' -Path $info.Path }
    $names = @()
    foreach ($ln in ($res.Stdout -split "`r?`n")) {
        if ($ln -match '^\s*-{3,}\s*$') { continue }
        if ($ln -match '^\s*Use\s+') { continue }
        if ($ln -match 'Workload\s+Id|Manifest\s+Version|Installation\s+Source') { continue }
        if ($ln -match '^\s*([a-z][a-z0-9-]+)\s+\d+\.\d') { $names += $matches[1] }
    }
    $ver = if ($names.Count -gt 0) { $names -join ', ' } else { 'none installed' }
    return New-Check -Name 'dotnet workload' -Status 'OK' -Version $ver -Category 'Language & Toolchain' -Path $info.Path
}

function Get-DotnetSdks {
    $info = Get-ExecutableInfo -Name 'dotnet'
    if (-not $info -or $info.IsStoreAlias) { return New-Check -Name 'dotnet SDKs' -Status 'MISSING' -Category 'Language & Toolchain' }
    $res = Invoke-NativeCapture -Exe $info.Path -Arguments @('--list-sdks')
    if (-not $res) { return New-Check -Name 'dotnet SDKs' -Status 'FAILED' -Version '(execution failed)' -Category 'Language & Toolchain' -Path $info.Path }
    $versions = @()
    foreach ($ln in ($res.Stdout -split "`r?`n")) {
        if ($ln -match '^(\d+\.\d+\.\d+)') { $versions += $matches[1] }
    }
    $ver = if ($versions.Count -gt 0) { $versions -join ', ' } else { 'none installed' }
    return New-Check -Name 'dotnet SDKs' -Status 'OK' -Version $ver -Category 'Language & Toolchain' -Path $info.Path
}

function Get-RustupInfo {
    $info = Get-ExecutableInfo -Name 'rustup'
    if (-not $info -or $info.IsStoreAlias) { return New-Check -Name 'rustup toolchain' -Status 'MISSING' -Category 'Language & Toolchain' }
    $res = Invoke-NativeCapture -Exe $info.Path -Arguments @('show', 'active-toolchain')
    if (-not $res) { return New-Check -Name 'rustup toolchain' -Status 'FAILED' -Version '(execution failed)' -Category 'Language & Toolchain' -Path $info.Path }
    $ver = Get-FirstNonEmptyLine $res.Stdout
    if (-not $ver) { $ver = 'unknown' }
    return New-Check -Name 'rustup toolchain' -Status 'OK' -Version $ver -Category 'Language & Toolchain' -Path $info.Path
}

function Get-VsWhereInfo {
    $vsWhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
    if (-not (Test-Path $vsWhere)) {
        return @(
            (New-Check -Name 'Visual Studio' -Status 'MISSING' -Category 'Toolchain Infrastructure'),
            (New-Check -Name 'MSBuild' -Status 'MISSING' -Category 'Build System')
        )
    }
    $results = @()
    $name = Get-FirstNonEmptyLine (Invoke-NativeCapture -Exe $vsWhere -Arguments @('-latest', '-property', 'displayName')).Stdout
    $ver = Get-FirstNonEmptyLine (Invoke-NativeCapture -Exe $vsWhere -Arguments @('-latest', '-property', 'installationVersion')).Stdout
    $vsPath = Get-FirstNonEmptyLine (Invoke-NativeCapture -Exe $vsWhere -Arguments @('-latest', '-property', 'installationPath')).Stdout
    if ($name) {
        $results += New-Check -Name 'Visual Studio' -Status 'OK' -Version "$name $ver".Trim() -Category 'Toolchain Infrastructure' -Path $vsPath
    } else {
        $results += New-Check -Name 'Visual Studio' -Status 'MISSING' -Category 'Toolchain Infrastructure'
    }
    $msbuild = Get-FirstNonEmptyLine (Invoke-NativeCapture -Exe $vsWhere -Arguments @('-latest', '-requires', 'Microsoft.Component.MSBuild', '-find', 'MSBuild\**\Bin\MSBuild.exe')).Stdout
    if ($msbuild -and (Test-Path $msbuild)) {
        $mver = Get-FirstNonEmptyLine (Invoke-NativeCapture -Exe $msbuild -Arguments @('-version', '-nologo')).Stdout
        if (-not $mver) { $mver = 'detected' }
        $results += New-Check -Name 'MSBuild' -Status 'OK' -Version $mver -Category 'Build System' -Path $msbuild
    } else {
        $results += New-Check -Name 'MSBuild' -Status 'MISSING' -Category 'Build System'
    }
    return $results
}

function Get-RPackages {
    $info = Get-ExecutableInfo -Name 'Rscript'
    if (-not $info -or $info.IsStoreAlias) { return @() }
    $checks = @()
    foreach ($pkg in @('bit64', 'future')) {
        $res = Invoke-NativeCapture -Exe $info.Path -Arguments @('-e', "cat(as.character(packageVersion('$pkg')))")
        $ver = Get-FirstNonEmptyLine $res.Stdout
        if ($ver -and $ver -match '^\d+\.\d+') {
            $checks += New-Check -Name "R package: $pkg" -Status 'OK' -Version $ver -Category 'Language & Toolchain' -Path $info.Path
        } else {
            $checks += New-Check -Name "R package: $pkg" -Status 'MISSING' -Category 'Language & Toolchain' -Path $info.Path
        }
    }
    return $checks
}

function Get-RtoolsInfo {
    $path = Get-FirstExistingPath @('C:\rtools45\bin\gcc.exe', 'C:\rtools44\bin\gcc.exe', 'C:\rtools43\bin\gcc.exe', 'C:\rtools42\bin\gcc.exe')
    if ($path) {
        $root = Split-Path (Split-Path $path -Parent) -Parent
        $ver = if ($root -match 'rtools(\d+)') { "rtools$($matches[1])" } else { 'detected' }
        return New-Check -Name 'Rtools' -Status 'OK' -Version $ver -Category 'Language & Toolchain' -Path $root
    }
    $rt = Get-ExecutableInfo -Name 'Rtools'
    if ($rt -and -not $rt.IsStoreAlias) {
        return New-Check -Name 'Rtools' -Status 'OK' -Version 'detected' -Category 'Language & Toolchain' -Path $rt.Path
    }
    return New-Check -Name 'Rtools' -Status 'MISSING' -Category 'Language & Toolchain'
}

function Get-JuliaPkgInfo {
    $info = Get-ExecutableInfo -Name 'julia'
    if (-not $info -or $info.IsStoreAlias) { return New-Check -Name 'Julia Pkg' -Status 'MISSING' -Category 'Language & Toolchain' }
    $res = Invoke-NativeCapture -Exe $info.Path -Arguments @('-e', 'using Pkg; Pkg.status()')
    $combined = if ($res) { "$($res.Stdout)`n$($res.Stderr)" } else { '' }
    $count = ($combined -split "`r?`n" | Where-Object { $_ -match '^\s*\[[0-9a-f]' }).Count
    $ver = if ($count -gt 0) { "$count packages in active env" } else { 'empty or no project' }
    return New-Check -Name 'Julia Pkg' -Status 'OK' -Version $ver -Category 'Language & Toolchain' -Path $info.Path
}

function Get-NpmGlobal {
    $info = Get-ExecutableInfo -Name 'npm'
    if (-not $info -or $info.IsStoreAlias) { return New-Check -Name 'npm global: typescript' -Status 'MISSING' -Category 'Language & Toolchain' }
    $res = Invoke-NativeCapture -Exe $info.Path -Arguments @('list', '-g', '--depth=0', '--parseable')
    $combined = if ($res) { "$($res.Stdout)`n$($res.Stderr)" } else { '' }
    $found = $false
    foreach ($ln in ($combined -split "`r?`n")) {
        if ($ln -match '[\\/]typescript$') { $found = $true; break }
    }
    if ($found) {
        return New-Check -Name 'npm global: typescript' -Status 'OK' -Version 'installed' -Category 'Language & Toolchain' -Path $info.Path
    }
    return New-Check -Name 'npm global: typescript' -Status 'MISSING' -Category 'Language & Toolchain' -Path $info.Path
}

function Get-PipCore {
    $info = Get-ExecutableInfo -Name 'pip'
    if (-not $info -or $info.IsStoreAlias) { return @() }
    $res = Invoke-NativeCapture -Exe $info.Path -Arguments @('list', '--format=freeze')
    $combined = if ($res) { "$($res.Stdout)`n$($res.Stderr)" } else { '' }
    $checks = @()
    foreach ($pkg in @('wheel', 'setuptools')) {
        $m = [regex]::Match($combined, "(?im)^$pkg==([\d.]+)")
        if ($m.Success) {
            $checks += New-Check -Name "pip core: $pkg" -Status 'OK' -Version $m.Groups[1].Value -Category 'Language & Toolchain' -Path $info.Path
        } else {
            $checks += New-Check -Name "pip core: $pkg" -Status 'MISSING' -Category 'Language & Toolchain' -Path $info.Path
        }
    }
    return $checks
}

function Get-RubyGem {
    $info = Get-ExecutableInfo -Name 'gem'
    if (-not $info -or $info.IsStoreAlias) { return New-Check -Name 'gem: ruby-lsp' -Status 'MISSING' -Category 'Language & Toolchain' }
    $res = Invoke-NativeCapture -Exe $info.Path -Arguments @('list', 'ruby-lsp')
    $combined = if ($res) { "$($res.Stdout)`n$($res.Stderr)" } else { '' }
    $m = [regex]::Match($combined, 'ruby-lsp\s+\(([\d.]+)\)')
    if ($m.Success) {
        return New-Check -Name 'gem: ruby-lsp' -Status 'OK' -Version $m.Groups[1].Value -Category 'Language & Toolchain' -Path $info.Path
    }
    return New-Check -Name 'gem: ruby-lsp' -Status 'MISSING' -Category 'Language & Toolchain' -Path $info.Path
}

function Get-ErlOtpVersion {
    if ($script:ErlOtp) { return $script:ErlOtp }
    $info = Get-ExecutableInfo -Name 'erl'
    if (-not $info -or $info.IsStoreAlias) { return $null }
    $res = Invoke-NativeCapture -Exe $info.Path -Arguments @('-noshell', '-eval', 'io:put_chars(erlang:system_info(otp_release)),halt().')
    if ($res -and $res.Stdout) {
        $v = $res.Stdout.Trim()
        if ($v) { $script:ErlOtp = $v }
    }
    return $script:ErlOtp
}

function Get-ErlcInfo {
    $info = Get-ExecutableInfo -Name 'erlc'
    if (-not $info -or $info.IsStoreAlias) { return New-Check -Name 'erlc' -Status 'MISSING' -Category 'Language & Toolchain' }
    $otp = Get-ErlOtpVersion
    $ver = if ($otp) { "(same as erl $otp)" } else { 'detected' }
    return New-Check -Name 'erlc' -Status 'OK' -Version $ver -Category 'Language & Toolchain' -Path $info.Path
}

function Get-TscInfo {
    $tsc = Get-ExecutableInfo -Name 'tsc'
    if ($tsc -and -not $tsc.IsStoreAlias) {
        return Get-ToolVersion -Name 'tsc' -Exe 'tsc' -Arguments @('--version') -Category 'Language & Toolchain'
    }

    $node = Get-ExecutableInfo -Name 'node'
    if ($node -and -not $node.IsStoreAlias) {
        $nodeRoot = Split-Path $node.Path -Parent
        foreach ($sub in @('node_modules\.bin\tsc.cmd', 'node_modules\.bin\tsc.ps1', 'node_modules\typescript\bin\tsc')) {
            $cand = Join-Path $nodeRoot $sub
            if (Test-Path $cand) {
                $r = Invoke-NativeCapture -Exe $cand -Arguments @('--version')
                $v = Get-FirstNonEmptyLine "$($r.Stdout)`n$($r.Stderr)"
                if ($v) {
                    return New-Check -Name 'tsc' -Status 'OK' -Version "$v (local)" -Category 'Language & Toolchain' -Path $cand
                }
            }
        }
    }

    $npm = Get-ExecutableInfo -Name 'npm'
    if ($npm -and -not $npm.IsStoreAlias) {
        $res = Invoke-NativeCapture -Exe $npm.Path -Arguments @('list', '-g', '--depth=0', '--parseable')
        $combined = if ($res) { "$($res.Stdout)`n$($res.Stderr)" } else { '' }
        foreach ($ln in ($combined -split "`r?`n")) {
            if ($ln -match '[\\/]typescript$') {
                $tscJs = Join-Path $ln 'bin\tsc'
                if (Test-Path $tscJs) {
                    $r = Invoke-NativeCapture -Exe $tscJs -Arguments @('--version')
                    $v = Get-FirstNonEmptyLine "$($r.Stdout)`n$($r.Stderr)"
                    if ($v) {
                        return New-Check -Name 'tsc' -Status 'OK' -Version "$v (npm-global)" -Category 'Language & Toolchain' -Path $ln
                    }
                }
                return New-Check -Name 'tsc' -Status 'OK' -Version 'npm-global package present' -Category 'Language & Toolchain' -Path $ln
            }
        }
    }

    $npx = Get-ExecutableInfo -Name 'npx'
    if (-not $npx -or $npx.IsStoreAlias) {
        return New-Check -Name 'tsc' -Status 'MISSING' -Category 'Language & Toolchain'
    }

    $res = Invoke-NativeCapture -Exe $npx.Path -Arguments @('--yes', '--package=typescript', 'tsc', '--version') -TimeoutMs 90000
    if (-not $res) {
        return New-Check -Name 'tsc' -Status 'FAILED' -Version '(execution failed)' -Category 'Language & Toolchain' -Path $npx.Path
    }
    if ($res.TimedOut) {
        return New-Check -Name 'tsc' -Status 'TIMEOUT' -Version '(>90000ms)' -Category 'Language & Toolchain' -Path $npx.Path
    }
    $rawVer = Get-FirstNonEmptyLine "$($res.Stdout)`n$($res.Stderr)"
    $resolved = Resolve-VersionOrFallback -RawVer $rawVer -ExitCode $res.ExitCode
    if (-not $resolved.Ok) {
        $note = Get-ShortSummary -Text $res.Stderr -MaxLen 200
        if (-not $note) { $note = Get-ShortSummary -Text $res.Stdout -MaxLen 200 }
        return New-Check -Name 'tsc' -Status 'FAILED' -Version $resolved.Ver -Category 'Language & Toolchain' -Path $npx.Path -Note $note
    }
    return New-Check -Name 'tsc' -Status 'OK' -Version "$($resolved.Ver) (via npx typescript)" -Category 'Language & Toolchain' -Path $npx.Path
}

$javaParser = {
    param($text)
    foreach ($ln in ($text -split "`r?`n")) {
        if ($ln -match '(?:java|openjdk) version "?([\w.]+)"?') {
            return ($ln -replace '\s+', ' ').Trim()
        }
    }
    return $null
}

$javacParser = {
    param($text)
    foreach ($ln in ($text -split "`r?`n")) {
        if ($ln -match '^javac\s+([\w.]+)') { return "javac $($matches[1])" }
    }
    return $null
}

function Get-NvidiaSmiInfo {
    $info = Get-ExecutableInfo -Name 'nvidia-smi'
    if (-not $info -or $info.IsStoreAlias) { return New-Check -Name 'nvidia-smi' -Status 'MISSING' -Category 'GPU & Graphics API' }
    $res = Invoke-NativeCapture -Exe $info.Path -Arguments @()
    $combined = if ($res) { "$($res.Stdout)`n$($res.Stderr)" } else { '' }
    $cuda = $null; $driver = $null
    foreach ($ln in ($combined -split "`r?`n")) {
        if (-not $cuda -and $ln -match 'CUDA(?: UMD)? Version:\s*([\d.]+)') { $cuda = $matches[1] }
        if (-not $driver -and $ln -match 'Driver Version:\s*([\d.]+)') { $driver = $matches[1] }
    }
    $parts = @()
    if ($cuda) { $parts += "CUDA $cuda (driver max)" }
    if ($driver) { $parts += "Driver $driver" }
    $ver = if ($parts) { $parts -join ' / ' } else { 'detected' }
    return New-Check -Name 'nvidia-smi' -Status 'OK' -Version $ver -Category 'GPU & Graphics API' -Path $info.Path
}

function Get-CudaToolkitInfo {
    $info = Get-ExecutableInfo -Name 'nvcc'
    $path = $null
    if ($info -and -not $info.IsStoreAlias) { $path = $info.Path }
    if (-not $path) {
        $cudaRoot = Get-FirstExistingPath @($env:CUDA_PATH, 'C:\Program Files\NVIDIA GPU Computing Toolkit\CUDA')
        if ($cudaRoot) {
            foreach ($d in (Get-ChildItem $cudaRoot -Directory -ErrorAction SilentlyContinue | Sort-Object Name -Descending)) {
                $candidate = Join-Path $d.FullName 'bin\nvcc.exe'
                if (Test-Path $candidate) { $path = $candidate; break }
            }
        }
    }
    if (-not $path) { return New-Check -Name 'CUDA Toolkit (nvcc)' -Status 'MISSING' -Category 'GPU & Graphics API' }
    $res = Invoke-NativeCapture -Exe $path -Arguments @('--version')
    $combined = if ($res) { "$($res.Stdout)`n$($res.Stderr)" } else { '' }
    $ver = $null
    if ($combined -match 'release\s+([\d.]+)') { $ver = $matches[1] }
    if (-not $ver) { $ver = 'detected' }
    return New-Check -Name 'CUDA Toolkit (nvcc)' -Status 'OK' -Version $ver -Category 'GPU & Graphics API' -Path $path
}

function Get-CudnnInfo {
    $root = Get-FirstExistingPath @($env:CUDNN_PATH, $env:CUDNN_HOME, 'C:\cudnn', 'C:\Program Files\NVIDIA\CUDNN')
    if (-not $root) { return New-Check -Name 'cuDNN' -Status 'MISSING' -Category 'GPU & Graphics API' }
    $ver = $null
    $header = Get-ChildItem -Path $root -Filter 'cudnn_version.h' -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($header) {
        $content = Get-Content $header.FullName -Raw -ErrorAction SilentlyContinue
        $maj = if ($content -match '#define\s+CUDNN_MAJOR\s+(\d+)') { $matches[1] } else { $null }
        $min = if ($content -match '#define\s+CUDNN_MINOR\s+(\d+)') { $matches[1] } else { $null }
        $pat = if ($content -match '#define\s+CUDNN_PATCHLEVEL\s+(\d+)') { $matches[1] } else { $null }
        if ($maj) { $ver = "$maj.$(if ($min) {$min} else {0}).$(if ($pat) {$pat} else {0})" }
    }
    if (-not $ver) {
        $dirName = Split-Path $root -Leaf
        if ($dirName -match 'cudnn[^\d]*([\d.]+)') { $ver = $matches[1] }
    }
    if (-not $ver) { $ver = "path=$root" }
    return New-Check -Name 'cuDNN' -Status 'OK' -Version $ver -Category 'GPU & Graphics API' -Path $root
}

function Get-TensorrtInfo {
    $root = Get-FirstExistingPath @($env:TENSORRT_PATH, 'C:\TensorRT', 'C:\Program Files\NVIDIA Corporation\TensorRT')
    if (-not $root) { return New-Check -Name 'TensorRT' -Status 'MISSING' -Category 'GPU & Graphics API' }
    $ver = $null
    $nvinfer = Get-ChildItem -Path $root -Filter 'nvinfer*.dll' -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($nvinfer) {
        $i = $nvinfer.VersionInfo
        if ($i) { $ver = "$($i.FileMajorPart).$($i.FileMinorPart).$($i.FileBuildPart)" }
    }
    if (-not $ver) {
        $dirName = Split-Path $root -Leaf
        if ($dirName -match 'TensorRT[^\d]*([\d.]+)') { $ver = $matches[1] }
    }
    if (-not $ver) { $ver = "path=$root" }
    return New-Check -Name 'TensorRT' -Status 'OK' -Version $ver -Category 'GPU & Graphics API' -Path $root
}

function Get-RocmInfo {
    $r = Get-ToolVersion -Name 'ROCm/HIP (hipconfig)' -Exe 'hipconfig' -Arguments @('--version') -Category 'GPU & Graphics API'
    if ($r.Status -eq 'OK') { return $r }
    $r = Get-ToolVersion -Name 'ROCm/HIP (hipInfo)' -Exe 'hipInfo.exe' -Arguments @('--version') -Category 'GPU & Graphics API'
    if ($r.Status -eq 'OK') { return $r }
    return New-Check -Name 'ROCm/HIP' -Status 'MISSING' -Category 'GPU & Graphics API'
}

function Get-VulkanInfo {
    $info = Get-ExecutableInfo -Name 'vulkaninfo'
    $path = $null
    if ($info -and -not $info.IsStoreAlias) { $path = $info.Path }
    elseif ($env:VULKAN_SDK) {
        $cand = Join-Path $env:VULKAN_SDK 'Bin\vulkaninfo.exe'
        if (Test-Path $cand) { $path = $cand }
    }
    if (-not $path) { return New-Check -Name 'vulkaninfo' -Status 'MISSING' -Category 'GPU & Graphics API' }
    $res = Invoke-NativeCapture -Exe $path -Arguments @('--summary')
    $combined = if ($res) { "$($res.Stdout)`n$($res.Stderr)" } else { '' }
    $ver = $null
    if ($combined -match 'Vulkan Instance Version:\s*([\d.]+)') { $ver = $matches[1] }
    if (-not $ver) { $ver = 'detected' }
    return New-Check -Name 'vulkaninfo' -Status 'OK' -Version $ver -Category 'GPU & Graphics API' -Path $path
}

function Get-OpenCLInfo {
    $info = Get-ExecutableInfo -Name 'clinfo'
    if (-not $info -or $info.IsStoreAlias) { return New-Check -Name 'clinfo' -Status 'MISSING' -Category 'GPU & Graphics API' }
    $res = Invoke-NativeCapture -Exe $info.Path -Arguments @()
    $combined = if ($res) { "$($res.Stdout)`n$($res.Stderr)" } else { '' }
    $ver = $null
    if ($combined -match 'Platform Version\s+OpenCL\s+([\d.]+)') { $ver = "OpenCL $($matches[1])" }
    elseif ($combined -match 'Platform Version\s+(.+)') { $ver = $matches[1].Trim() }
    if (-not $ver) { $ver = 'detected' }
    return New-Check -Name 'clinfo' -Status 'OK' -Version $ver -Category 'GPU & Graphics API' -Path $info.Path
}

function Get-OpenGLInfo {
    $path = $null
    foreach ($c in @('wglinfo64.exe', 'wglinfo.exe')) {
        $info = Get-ExecutableInfo -Name $c
        if ($info -and -not $info.IsStoreAlias) { $path = $info.Path; break }
    }
    if (-not $path) { return New-Check -Name 'wglinfo' -Status 'MISSING' -Category 'GPU & Graphics API' }
    $res = Invoke-NativeCapture -Exe $path -Arguments @()
    $combined = if ($res) { "$($res.Stdout)`n$($res.Stderr)" } else { '' }
    $ver = $null
    if ($combined -match 'OpenGL.*version string:\s*([\d.]+)') { $ver = $matches[1] }
    if (-not $ver) { $ver = 'detected' }
    return New-Check -Name 'wglinfo' -Status 'OK' -Version $ver -Category 'GPU & Graphics API' -Path $path
}

function Get-DirectXInfo {
    $prop = Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\DirectX' -Name Version -ErrorAction SilentlyContinue
    if ($prop -and $prop.Version) {
        return New-Check -Name 'DirectX (registry)' -Status 'OK' -Version "$($prop.Version) (legacy DX9-era value)" -Category 'GPU & Graphics API' -Path 'HKLM:\SOFTWARE\Microsoft\DirectX'
    }
    return New-Check -Name 'DirectX (registry)' -Status 'MISSING' -Category 'GPU & Graphics API'
}

function Get-7ZipInfo {
    $info = Get-ExecutableInfo -Name '7z'
    $path = $null
    if ($info -and -not $info.IsStoreAlias) { $path = $info.Path }
    else { $path = Get-FirstExistingPath @('C:\Program Files\7-Zip\7z.exe', 'C:\Program Files (x86)\7-Zip\7z.exe') }
    if (-not $path) { return New-Check -Name '7-Zip' -Status 'MISSING' -Category 'Toolchain Infrastructure' }
    $res = Invoke-NativeCapture -Exe $path -Arguments @('-version')
    $combined = if ($res) { "$($res.Stdout)`n$($res.Stderr)" } else { '' }
    $ver = $null
    if ($combined -match '7-Zip\s+([\d.]+)') { $ver = $matches[1] }
    if (-not $ver) { $ver = 'detected' }
    return New-Check -Name '7-Zip' -Status 'OK' -Version $ver -Category 'Toolchain Infrastructure' -Path $path
}

$results = @()

$langTools = @(
    @{ Name = 'fpc'; Exe = 'fpc'; Args = @('-iV') },
    @{ Name = 'lazbuild'; Exe = 'lazbuild'; Args = @('--version') },
    @{ Name = 'python'; Exe = 'python'; Args = @('--version'); Fallback = 'python3' },
    @{ Name = 'pip'; Exe = 'pip'; Args = @('--version') },
    @{ Name = 'gcc'; Exe = 'gcc'; Args = @('--version') },
    @{ Name = 'g++'; Exe = 'g++'; Args = @('--version') },
    @{ Name = 'clang'; Exe = 'clang'; Args = @('--version') },
    @{ Name = 'clang++'; Exe = 'clang++'; Args = @('--version') },
    @{ Name = 'dotnet'; Exe = 'dotnet'; Args = @('--version') },
    @{ Name = 'cargo'; Exe = 'cargo'; Args = @('--version') },
    @{ Name = 'rustc'; Exe = 'rustc'; Args = @('--version') },
    @{ Name = 'go'; Exe = 'go'; Args = @('version') },
    @{ Name = 'node'; Exe = 'node'; Args = @('--version') },
    @{ Name = 'npm'; Exe = 'npm'; Args = @('--version') },
    @{ Name = 'erl'; Exe = 'erl'; Args = @('-noshell', '-eval', 'io:put_chars(erlang:system_info(otp_release)),halt().') },
    @{ Name = 'elixir'; Exe = 'elixir'; Args = @('--version') },
    @{ Name = 'julia'; Exe = 'julia'; Args = @('--version') },
    @{ Name = 'zig'; Exe = 'zig'; Args = @('version') },
    @{ Name = 'swift'; Exe = 'swift'; Args = @('--version') },
    @{ Name = 'ruby'; Exe = 'ruby'; Args = @('-v') },
    @{ Name = 'gem'; Exe = 'gem'; Args = @('-v') },
    @{ Name = 'gfortran'; Exe = 'gfortran'; Args = @('--version') },
    @{ Name = 'dart'; Exe = 'dart'; Args = @('--version') },
    @{ Name = 'Rscript'; Exe = 'Rscript'; Args = @('--version') },
    @{ Name = 'php'; Exe = 'php'; Args = @('-v') }
)
foreach ($t in $langTools) {
    $results += Get-ToolVersion -Name $t.Name -Exe $t.Exe -Arguments $t.Args -Fallback $t.Fallback -Category 'Language & Toolchain'
}

$results += Get-ToolVersion -Name 'java' -Exe 'java' -Arguments @('-version') -Category 'Language & Toolchain' -VersionParser $javaParser
$results += Get-ToolVersion -Name 'javac' -Exe 'javac' -Arguments @('-version') -Category 'Language & Toolchain' -VersionParser $javacParser
$results += Get-TscInfo
$results += Get-ErlcInfo

$results += Get-DelphiInfo
$results += Get-GoEnvInfo
$results += Get-DotnetWorkloads
$results += Get-DotnetSdks
$results += Get-RustupInfo
$results += Get-RPackages
$results += Get-RtoolsInfo
$results += Get-JuliaPkgInfo
$results += Get-NpmGlobal
$results += Get-PipCore
$results += Get-RubyGem

$pkgManagers = @(
    @{ Name = 'choco'; Exe = 'choco'; Args = @('-v') },
    @{ Name = 'scoop'; Exe = 'scoop'; Args = @('--version') },
    @{ Name = 'winget'; Exe = 'winget'; Args = @('--version') },
    @{ Name = 'conda'; Exe = 'conda'; Args = @('--version') },
    @{ Name = 'pipx'; Exe = 'pipx'; Args = @('--version') },
    @{ Name = 'uv'; Exe = 'uv'; Args = @('--version') },
    @{ Name = 'nuget'; Exe = 'nuget'; Args = @('help') },
    @{ Name = 'conan'; Exe = 'conan'; Args = @('version') }
)
foreach ($t in $pkgManagers) {
    $results += Get-ToolVersion -Name $t.Name -Exe $t.Exe -Arguments $t.Args -Category 'Package Manager'
}
$results += Get-VcpkgInfo

$buildTools = @(
    @{ Name = 'CMake'; Exe = 'cmake'; Args = @('--version') },
    @{ Name = 'Ninja'; Exe = 'ninja'; Args = @('--version') },
    @{ Name = 'Meson'; Exe = 'meson'; Args = @('--version') },
    @{ Name = 'Maven'; Exe = 'mvn'; Args = @('-v') },
    @{ Name = 'Gradle'; Exe = 'gradle'; Args = @('--version') },
    @{ Name = 'sbt'; Exe = 'sbt'; Args = @('--version') },
    @{ Name = 'rebar3'; Exe = 'rebar3'; Args = @('--version') },
    @{ Name = 'mix'; Exe = 'mix'; Args = @('--version') },
    @{ Name = 'Stack'; Exe = 'stack'; Args = @('--version') },
    @{ Name = 'Cabal'; Exe = 'cabal'; Args = @('--version') }
)
foreach ($t in $buildTools) {
    $results += Get-ToolVersion -Name $t.Name -Exe $t.Exe -Arguments $t.Args -Category 'Build System'
}
$results += Get-VsWhereInfo

$infra = @(
    @{ Name = 'Git'; Exe = 'git'; Args = @('--version') },
    @{ Name = 'NASM'; Exe = 'nasm'; Args = @('-v') },
    @{ Name = 'Make'; Exe = 'make'; Args = @('--version') },
    @{ Name = 'pkg-config'; Exe = 'pkg-config'; Args = @('--version') },
    @{ Name = 'OpenSSL'; Exe = 'openssl'; Args = @('version') },
    @{ Name = 'curl'; Exe = 'curl'; Args = @('--version') },
    @{ Name = 'tar'; Exe = 'tar'; Args = @('--version') }
)
foreach ($t in $infra) {
    $results += Get-ToolVersion -Name $t.Name -Exe $t.Exe -Arguments $t.Args -Category 'Toolchain Infrastructure'
}
$results += Get-Msys2Info
$results += Get-7ZipInfo

$results += Get-NvidiaSmiInfo
$results += Get-CudaToolkitInfo
$results += Get-CudnnInfo
$results += Get-TensorrtInfo
$results += Get-RocmInfo
$results += Get-VulkanInfo
$results += Get-OpenCLInfo
$results += Get-OpenGLInfo
$results += Get-DirectXInfo

$gpuControllers = Get-CimInstance Win32_VideoController -ErrorAction SilentlyContinue | Select-Object Name, DriverVersion
$osInfo = Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue

$okCount = @($results | Where-Object { $_.Status -eq 'OK' }).Count
$missingCount = @($results | Where-Object { $_.Status -eq 'MISSING' }).Count
$failedCount = @($results | Where-Object { $_.Status -eq 'FAILED' -or $_.Status -eq 'TIMEOUT' }).Count
$storeAliasCount = @($results | Where-Object { $_.Status -eq 'STORE-ALIAS' }).Count

if ($Json) {
    [pscustomobject]@{
        Timestamp = Get-Date -Format 'o'
        Summary = [pscustomobject]@{
            OK = $okCount; MISSING = $missingCount; FAILED = $failedCount
            STORE_ALIAS = $storeAliasCount; Total = $results.Count
        }
        Checks = $results
        GPU = $gpuControllers
        OS = [pscustomobject]@{
            Caption = if ($osInfo) { $osInfo.Caption } else { [System.Environment]::OSVersion.VersionString }
            Version = if ($osInfo) { $osInfo.Version } else { [System.Environment]::OSVersion.Version.ToString() }
            Architecture = if ([System.Environment]::Is64BitOperatingSystem) { '64-bit' } else { '32-bit' }
            PowerShell = $PSVersionTable.PSVersion.ToString()
        }
    } | ConvertTo-Json -Depth 5
    exit 0
}

Write-Host '============================================================' -ForegroundColor Cyan
Write-Host ' LingoFuse Full Environment Check'
Write-Host '============================================================' -ForegroundColor Cyan
Write-Host (" OS        : {0}" -f $(if ($osInfo) { $osInfo.Caption } else { [System.Environment]::OSVersion.VersionString }))
Write-Host (" PowerShell: {0}" -f $PSVersionTable.PSVersion)
Write-Host (" Time      : {0}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))
Write-Host ''

foreach ($cat in @('Language & Toolchain','Package Manager','Build System','Toolchain Infrastructure','GPU & Graphics API')) {
    $items = @($results | Where-Object { $_.Category -eq $cat })
    if ($items.Count -eq 0) { continue }
    Write-Host ("--- {0} ---" -f $cat) -ForegroundColor Cyan
    foreach ($item in $items) {
        $color = switch ($item.Status) {
            'OK'          { 'Green' }
            'STORE-ALIAS' { 'Yellow' }
            'FAILED'      { 'Magenta' }
            'TIMEOUT'     { 'Magenta' }
            default       { 'Red' }
        }
        $displayVer = ''
        if ($item.Status -eq 'MISSING') {
            $displayVer = ''
        } elseif ($item.Version) {
            $displayVer = $item.Version.Trim()
        }
        if ($displayVer.Length -eq 0 -and $item.Status -ne 'MISSING') { $displayVer = '(no output)' }
        Write-Host ("  {0,-32} {1,-12} {2}" -f $item.Name, $item.Status, $displayVer) -ForegroundColor $color
        if ($item.Path) {
            Write-Host ("  {0,-32} {1}" -f '', $item.Path) -ForegroundColor DarkGray
        }
        if ($item.Note) {
            Write-Host ("  {0,-32} note: {1}" -f '', $item.Note) -ForegroundColor DarkGray
        }
    }
    Write-Host ''
}

if ($gpuControllers) {
    Write-Host '--- GPU Hardware (WMI) ---' -ForegroundColor Cyan
    foreach ($gpu in $gpuControllers) {
        $tag = ''
        if ($gpu.Name -match 'ASPEED|Basic Display|Microsoft Basic') { $tag = ' [virtual/manage]' }
        Write-Host ("  {0}  [Driver {1}]{2}" -f $gpu.Name, $gpu.DriverVersion, $tag)
    }
    Write-Host ''
}

Write-Host '============================================================' -ForegroundColor Cyan
Write-Host (" Summary: {0} OK / {1} MISSING / {2} FAILED / {3} STORE-ALIAS / {4} TOTAL" -f $okCount, $missingCount, $failedCount, $storeAliasCount, $results.Count) -ForegroundColor Cyan
if ($missingCount -gt 0) {
    Write-Host ' Missing:' -ForegroundColor Yellow
    $results | Where-Object { $_.Status -eq 'MISSING' } | ForEach-Object {
        Write-Host ("   - {0}" -f $_.Name) -ForegroundColor Yellow
    }
}
if ($failedCount -gt 0) {
    Write-Host ' Failed:' -ForegroundColor Magenta
    $results | Where-Object { $_.Status -eq 'FAILED' -or $_.Status -eq 'TIMEOUT' } | ForEach-Object {
        $line = "   - {0}  ({1})" -f $_.Name, $_.Version
        if ($_.Note) { $line += "  note: $($_.Note)" }
        Write-Host $line -ForegroundColor Magenta
    }
}
if ($storeAliasCount -gt 0) {
    Write-Host ' Store-Alias (not a real install):' -ForegroundColor Yellow
    $results | Where-Object { $_.Status -eq 'STORE-ALIAS' } | ForEach-Object {
        Write-Host ("   - {0}  ->  {1}" -f $_.Name, $_.Path) -ForegroundColor Yellow
    }
}
Write-Host '============================================================' -ForegroundColor Cyan

if ($missingCount -eq 0 -and $failedCount -eq 0 -and $storeAliasCount -eq 0) { exit 0 } else { exit 1 }