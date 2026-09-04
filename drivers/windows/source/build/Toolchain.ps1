[CmdletBinding()]
$ErrorActionPreference='Stop'

function Find-MSBuild {
    $vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
    if (Test-Path -LiteralPath $vswhere) {
        $vs = & $vswhere -latest -products * -requires Microsoft.Component.MSBuild -property installationPath
        if ($vs) {
            $vs = ($vs | Select-Object -First 1).Trim()
            # WDK validation tasks are architecture-sensitive on recent kits.
            # Prefer the native 64-bit MSBuild host for x64 driver builds.
            foreach ($relative in @('MSBuild\Current\Bin\amd64\MSBuild.exe','MSBuild\Current\Bin\MSBuild.exe')) {
                $candidate = Join-Path $vs $relative
                if (Test-Path -LiteralPath $candidate) {
                    return [pscustomobject]@{
                        VS=$vs
                        MSBuild=$candidate
                        MSBuildHost=if ($relative.Contains('\amd64\')) {'amd64'} else {'x86'}
                    }
                }
            }
        }
    }

    # Fallback for machines where vswhere has not been refreshed yet. Discover
    # any Current MSBuild, ranking the amd64 host ahead of the 32-bit host.
    $roots = @($env:ProgramFiles, ${env:ProgramFiles(x86)}) | Where-Object { $_ -and (Test-Path -LiteralPath $_) }
    foreach ($r in $roots) {
        $base = Join-Path $r 'Microsoft Visual Studio'
        if (!(Test-Path -LiteralPath $base)) { continue }
        $hits = @(Get-ChildItem -LiteralPath $base -Recurse -File -Filter MSBuild.exe -ErrorAction SilentlyContinue |
            Where-Object {
                $normalized=$_.FullName.Replace('/','\')
                $normalized.EndsWith('\MSBuild\Current\Bin\amd64\MSBuild.exe',[StringComparison]::OrdinalIgnoreCase) -or
                $normalized.EndsWith('\MSBuild\Current\Bin\MSBuild.exe',[StringComparison]::OrdinalIgnoreCase)
            })
        $hit = $hits | Sort-Object @{Expression={if($_.FullName.Replace('/','\').Contains('\Bin\amd64\')){1}else{0}};Descending=$true}, @{Expression='LastWriteTime';Descending=$true} | Select-Object -First 1
        if ($hit) {
            $normalized=$hit.FullName.Replace('/','\')
            $marker='\MSBuild\Current\Bin\'
            $index=$normalized.IndexOf($marker,[StringComparison]::OrdinalIgnoreCase)
            if($index -lt 0){continue}
            $vsRoot=$normalized.Substring(0,$index)
            return [pscustomobject]@{
                VS=$vsRoot
                MSBuild=$hit.FullName
                MSBuildHost=if($normalized.Contains('\Bin\amd64\')){'amd64'}else{'x86'}
            }
        }
    }
    return $null
}

function Find-VCPlatformToolset([string]$vsRoot) {
    $base = Join-Path $vsRoot 'MSBuild\Microsoft\VC'
    if (!(Test-Path -LiteralPath $base)) { return $null }
    $hits = Get-ChildItem -LiteralPath $base -Recurse -Directory -ErrorAction SilentlyContinue |
        Where-Object { $_.Parent -and $_.Parent.Name -eq 'PlatformToolsets' -and $_.Name -match '^v\d+$' }
    if (!$hits) { return $null }
    return ($hits | Sort-Object @{Expression={ [int]($_.Name.Substring(1)) };Descending=$true} | Select-Object -First 1).Name
}

function Get-KitsRoots {
    $roots = New-Object System.Collections.Generic.List[string]

    if ($env:WindowsSdkDir) { $roots.Add($env:WindowsSdkDir.TrimEnd('\')) }

    foreach ($regPath in @(
        'HKLM:\SOFTWARE\Microsoft\Windows Kits\Installed Roots',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows Kits\Installed Roots'
    )) {
        $r = Get-ItemProperty -Path $regPath -ErrorAction SilentlyContinue
        if ($null -ne $r) {
            foreach ($name in 'KitsRoot10','KitsRoot11') {
                $v = $r.$name
                if ($v) { $roots.Add($v.TrimEnd('\')) }
            }
        }
    }

    foreach ($base in @(${env:ProgramFiles(x86)}, $env:ProgramFiles)) {
        if (!$base) { continue }
        foreach ($leaf in 'Windows Kits\10','Windows Kits\11') {
            $candidate = Join-Path $base $leaf
            if (Test-Path -LiteralPath $candidate) { $roots.Add($candidate.TrimEnd('\')) }
        }
    }

    return @($roots | Where-Object { $_ -and (Test-Path -LiteralPath $_) } | Select-Object -Unique)
}

function Get-ToolVersionScore([string]$path) {
    $score = 0L
    if ($path -match '\\x64\\') { $score += 1000000000000000L }
    elseif ($path -match '\\amd64\\') { $score += 900000000000000L }
    elseif ($path -match '\\x86\\') { $score += 100000000000000L }

    # Prefer the highest Windows Kit folder when several SDK/WDK generations
    # coexist.  This works for 10.0.26100.0, 10.0.28000.0, etc.
    if ($path -match '(?i)\\(\d+)\.(\d+)\.(\d+)\.(\d+)\\') {
        $score += ([int64]$Matches[1] * 100000000000L)
        $score += ([int64]$Matches[2] * 100000000L)
        $score += ([int64]$Matches[3] * 1000L)
        $score += [int64]$Matches[4]
    }
    return $score
}

function Find-KitTool([string]$name, [string[]]$subdirs) {
    $hits = @()
    foreach ($kit in Get-KitsRoots) {
        foreach ($subdir in $subdirs) {
            $base = Join-Path $kit $subdir
            if (!(Test-Path -LiteralPath $base)) { continue }
            $hits += Get-ChildItem -LiteralPath $base -Recurse -File -Filter $name -ErrorAction SilentlyContinue
        }
    }
    if (!$hits) { return $null }
    return $hits |
        Sort-Object @{Expression={ Get-ToolVersionScore $_.FullName };Descending=$true}, @{Expression='LastWriteTime';Descending=$true} |
        Select-Object -First 1
}

function Find-KitToolX64([string]$name, [string[]]$subdirs) {
    $hits = @()
    foreach ($kit in Get-KitsRoots) {
        foreach ($subdir in $subdirs) {
            $base = Join-Path $kit $subdir
            if (!(Test-Path -LiteralPath $base)) { continue }
            $hits += Get-ChildItem -LiteralPath $base -Recurse -File -Filter $name -ErrorAction SilentlyContinue |
                Where-Object { $_.FullName.Replace('/','\').Contains('\x64\') }
        }
    }
    if (!$hits) { return $null }
    return $hits |
        Sort-Object @{Expression={ Get-ToolVersionScore $_.FullName };Descending=$true}, @{Expression='LastWriteTime';Descending=$true} |
        Select-Object -First 1
}

function Get-KitVersionFromTool([System.IO.FileInfo]$tool) {
    if (!$tool) { return $null }
    if ($tool.FullName -match '(?i)\\(\d+\.\d+\.\d+\.\d+)\\(?:x64|x86|arm64)\\[^\\]+$') {
        return $Matches[1]
    }
    return $null
}

function Find-VersionedKitTool(
    [string]$Root,
    [string]$Version,
    [string]$Name,
    [string[]]$Subdirs,
    [string[]]$Architectures=@('x64','amd64','x86')
) {
    # Windows Kits do not keep every tool in the same layout. Inf2Cat is
    # commonly under bin\<version>\<arch>, while InfVerif can be under either
    # Tools\<arch> or a versioned folder depending on the WDK generation.
    foreach ($subdir in $Subdirs) {
        $base = Join-Path $Root $subdir
        if (!(Test-Path -LiteralPath $base)) { continue }

        foreach ($candidateRoot in @((Join-Path $base $Version), $base)) {
            if (!(Test-Path -LiteralPath $candidateRoot)) { continue }
            foreach ($arch in $Architectures) {
                $candidate = Join-Path (Join-Path $candidateRoot $arch) $Name
                if (Test-Path -LiteralPath $candidate -PathType Leaf) {
                    return Get-Item -LiteralPath $candidate
                }
            }
        }

        $versionNeedle='\' + $Version + '\'
        $fallback = Get-ChildItem -LiteralPath $base -Recurse -File -Filter $Name -ErrorAction SilentlyContinue |
            Where-Object {
                $normalized=$_.FullName.Replace('/','\')
                $normalized.IndexOf($versionNeedle,[StringComparison]::OrdinalIgnoreCase) -ge 0
            } |
            Sort-Object @{Expression={ Get-ToolVersionScore $_.FullName };Descending=$true}, @{Expression='FullName';Descending=$false} |
            Select-Object -First 1
        if ($fallback) { return $fallback }
    }
    return $null
}

function Find-CoherentWdk {
    $candidates = @()
    foreach ($root in Get-KitsRoots) {
        $includeRoot = Join-Path $root 'Include'
        if (!(Test-Path -LiteralPath $includeRoot)) { continue }
        $versions = Get-ChildItem -LiteralPath $includeRoot -Directory -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -match '^\d+\.\d+\.\d+\.\d+$' }
        foreach ($versionDir in $versions) {
            $version = $versionDir.Name

            # This project ships no authored kernel .sys. It needs a coherent
            # user-mode Windows SDK plus the WDK packaging tools, not KMDF/
            # ntoskrnl development headers. Requiring those kernel-only files
            # rejected otherwise valid Visual Studio + WDK installations.
            $windowsHeader = Join-Path $versionDir.FullName 'um\Windows.h'
            $sharedHeader = Join-Path $versionDir.FullName 'shared\winerror.h'
            $kernel32 = Join-Path $root "Lib\$version\um\x64\kernel32.lib"
            if (!(Test-Path -LiteralPath $windowsHeader -PathType Leaf) -or
                !(Test-Path -LiteralPath $sharedHeader -PathType Leaf) -or
                !(Test-Path -LiteralPath $kernel32 -PathType Leaf)) { continue }

            $infVerif = Find-VersionedKitTool $root $version 'InfVerif.exe' @('Tools','tools','bin') @('x64','amd64','x86')
            $inf2Cat = Find-VersionedKitTool $root $version 'Inf2Cat.exe' @('bin','Tools','tools') @('x64','amd64','x86')
            if (!$infVerif -or !$inf2Cat) { continue }

            $candidates += [pscustomobject]@{
                Root = $root.TrimEnd('\')
                Version = $version
                VersionObject = [version]$version
                WindowsHeader = $windowsHeader
                Kernel32 = $kernel32
                InfVerif = $infVerif.FullName
                Inf2Cat = $inf2Cat.FullName
            }
        }
    }

    $selected = $candidates |
        Sort-Object @{Expression='VersionObject';Descending=$true}, @{Expression='Root';Descending=$false} |
        Select-Object -First 1
    if (!$selected) {
        $roots = (Get-KitsRoots) -join '; '
        throw "No usable x64 Windows SDK/WDK installation was found. The build requires Windows SDK headers/libs plus InfVerif and Inf2Cat. Roots checked: $roots"
    }
    return $selected
}

$build = Find-MSBuild
if (!$build) {
    throw 'Microsoft Visual Studio/MSBuild was not found. Install Visual Studio C++ tools and the Windows Driver Kit (WDK).'
}
$platformToolset = Find-VCPlatformToolset $build.VS
if (!$platformToolset) {
    throw "No installed x64 Visual C++ PlatformToolset was found under $($build.VS)."
}

# Select one coherent Windows SDK/WDK root instead of independently choosing
# unrelated headers, libraries and packaging tools. This project contains no
# authored kernel .sys, so KMDF/ntoskrnl development files are intentionally
# not prerequisites; the build needs the x64 user-mode SDK plus InfVerif/Inf2Cat.
$wdk = Find-CoherentWdk
$iv = Get-Item -LiteralPath $wdk.InfVerif
$ic = Get-Item -LiteralPath $wdk.Inf2Cat
$wdkVersion = [string]$wdk.Version
# WDKContentRoot is not a normal arbitrary directory property. Several WDK
# .props/.targets files concatenate it directly with relative paths such as
# "build\..." instead of using a path join. Preserve the native Windows Kits
# contract by always exposing a trailing directory separator to MSBuild.
$wdkRoot = ([string]$wdk.Root).TrimEnd([char[]]@('\','/')) + '\'
# Windows PowerShell 5.x native-process argument marshaling can misquote an
# argument that contains spaces and ends in a backslash. Keep WdkRoot in the
# native WDK form above, but expose an MSBuild command-line equivalent ending
# in '/' so the closing quote cannot be escaped. Windows/MSBuild accepts '/'
# as a directory separator, and direct WDK concatenations still remain valid.
$wdkMsBuildRoot = $wdkRoot.TrimEnd([char[]]@('\','/')) + '/'
$st = Find-VersionedKitTool $wdkRoot $wdkVersion 'signtool.exe' @('bin') @('x64','amd64','x86')
if (!$st) { $st = Find-KitTool 'signtool.exe' @('bin') }

$dumpbin = Get-ChildItem -LiteralPath (Join-Path $build.VS 'VC\Tools\MSVC') -Recurse -File -Filter dumpbin.exe -ErrorAction SilentlyContinue |
    Where-Object { $_.FullName -match '\\bin\\Hostx64\\x64\\dumpbin\.exe$' -or $_.FullName -match '\\bin\\HostX86\\x64\\dumpbin\.exe$' } |
    Sort-Object FullName -Descending | Select-Object -First 1
if (!$dumpbin) { throw 'x64 dumpbin.exe was not found in the Visual C++ toolchain.' }

$result = [pscustomobject]@{
    VS        = $build.VS
    MSBuild   = $build.MSBuild
    MSBuildHost = $build.MSBuildHost
    PlatformToolset = $platformToolset
    InfVerif  = $iv.FullName
    Inf2Cat   = $ic.FullName
    SignTool  = if ($st) { $st.FullName } else { $null }
    WdkVersion = $wdkVersion
    WdkRoot    = $wdkRoot
    WdkMsBuildRoot = $wdkMsBuildRoot
    WindowsHeader = $wdk.WindowsHeader
    Kernel32Lib = $wdk.Kernel32
    DumpBin   = $dumpbin.FullName
    KitsRoots = (Get-KitsRoots)
}

# Make the transcript useful. Write-Host does not contaminate the returned
# object consumed by Build.ps1. V1 has no Python build dependency.
Write-Host 'Build toolchain detected:' -ForegroundColor Green
Write-Host "  Visual Studio : $($result.VS)"
Write-Host "  MSBuild       : $($result.MSBuild)"
Write-Host "  MSBuild host  : $($result.MSBuildHost)"
Write-Host "  PlatformToolset: $($result.PlatformToolset)"
Write-Host "  InfVerif      : $($result.InfVerif)"
Write-Host "  Inf2Cat       : $($result.Inf2Cat)"
if ($result.SignTool) { Write-Host "  SignTool      : $($result.SignTool)" }
Write-Host "  WDK version   : $($result.WdkVersion)"
Write-Host "  WDK root      : $($result.WdkRoot)"
Write-Host "  WDK MSBuild root: $($result.WdkMsBuildRoot)"
Write-Host "  Windows.h     : $($result.WindowsHeader)"
Write-Host "  DumpBin       : $($result.DumpBin)"

$result
