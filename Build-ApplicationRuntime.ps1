[CmdletBinding()]
param(
    [string]$JdkHome = ''
)

$ErrorActionPreference = 'Stop'
$RepoRoot    = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$AppRoot     = Join-Path $RepoRoot 'applications\binaries\windows-x64'
$LibRoot     = Join-Path $AppRoot 'lib'
$RuntimeRoot = Join-Path $AppRoot 'java'
$LogPath     = Join-Path $RepoRoot 'applications\binaries\windows-x64\BUILD-APPLICATION-RUNTIME.log'

function Require-File([string]$Path, [string]$Label) {
    if (!(Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "$Label not found: $Path"
    }
}

function Add-Candidate {
    param(
        [System.Collections.Generic.List[string]]$List,
        [string]$Path
    )
    if ([string]::IsNullOrWhiteSpace($Path)) { return }
    try {
        $full = [System.IO.Path]::GetFullPath($Path)
    } catch {
        $full = $Path
    }
    if (!$List.Contains($full)) { $List.Add($full) }
}

function Find-JdkBin([string]$ExplicitHome) {
    $candidates = New-Object 'System.Collections.Generic.List[string]'

    if ($ExplicitHome) { Add-Candidate $candidates (Join-Path $ExplicitHome 'bin') }
    if ($env:JDK_HOME) { Add-Candidate $candidates (Join-Path $env:JDK_HOME 'bin') }
    if ($env:JAVA_HOME) { Add-Candidate $candidates (Join-Path $env:JAVA_HOME 'bin') }

    foreach ($toolName in @('jdeps.exe', 'jlink.exe', 'javac.exe', 'java.exe')) {
        $cmd = Get-Command $toolName -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($cmd -and $cmd.Source) {
            Add-Candidate $candidates (Split-Path -Parent $cmd.Source)
        }
    }

    $vendorNames = @(
        'Eclipse Adoptium',
        'Java',
        'Microsoft',
        'Amazon Corretto',
        'BellSoft',
        'Zulu',
        'Semeru'
    )

    foreach ($base in @($env:ProgramFiles, ${env:ProgramFiles(x86)})) {
        if (!$base) { continue }

        foreach ($vendor in $vendorNames) {
            $root = Join-Path $base $vendor
            if (!(Test-Path -LiteralPath $root -PathType Container)) { continue }

            Get-ChildItem -LiteralPath $root -Directory -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -match '^(jdk|jdk-|zulu|corretto|semeru|liberica)' } |
                Sort-Object LastWriteTime -Descending |
                ForEach-Object { Add-Candidate $candidates (Join-Path $_.FullName 'bin') }
        }
    }

    # Some JDK installers place their folders directly under Program Files.
    foreach ($base in @($env:ProgramFiles, ${env:ProgramFiles(x86)})) {
        if (!$base -or !(Test-Path -LiteralPath $base -PathType Container)) { continue }
        Get-ChildItem -LiteralPath $base -Directory -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -match '^(jdk-|jdk\d|zulu\d|corretto-)' } |
            ForEach-Object { Add-Candidate $candidates (Join-Path $_.FullName 'bin') }
    }

    foreach ($bin in $candidates) {
        $hasJdeps = Test-Path -LiteralPath (Join-Path $bin 'jdeps.exe') -PathType Leaf
        $hasJlink = Test-Path -LiteralPath (Join-Path $bin 'jlink.exe') -PathType Leaf
        $hasJava  = Test-Path -LiteralPath (Join-Path $bin 'java.exe')  -PathType Leaf
        if ($hasJdeps -and $hasJlink -and $hasJava) {
            return [pscustomobject]@{
                Bin        = $bin
                Candidates = @($candidates)
            }
        }
    }

    return [pscustomobject]@{
        Bin        = $null
        Candidates = @($candidates)
    }
}

function Write-ErrorLog {
    param(
        [System.Management.Automation.ErrorRecord]$ErrorRecord,
        [string[]]$JdkCandidates = @()
    )

    $lines = New-Object 'System.Collections.Generic.List[string]'
    $lines.Add('SynKinect BUILD-APPLICATION-RUNTIME error report')
    $lines.Add(('Date: {0}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss zzz')))
    $lines.Add(('PowerShell: {0}' -f $PSVersionTable.PSVersion))
    $lines.Add(('Repository: {0}' -f $RepoRoot))
    $lines.Add(('JAVA_HOME: {0}' -f $env:JAVA_HOME))
    $lines.Add(('JDK_HOME: {0}' -f $env:JDK_HOME))
    $lines.Add('')
    $lines.Add('ERROR:')
    $lines.Add($ErrorRecord.Exception.Message)
    $lines.Add('')

    if ($ErrorRecord.InvocationInfo) {
        $lines.Add(('At: {0}:{1}' -f $ErrorRecord.InvocationInfo.ScriptName, $ErrorRecord.InvocationInfo.ScriptLineNumber))
        $lines.Add(('Command: {0}' -f $ErrorRecord.InvocationInfo.Line.Trim()))
        $lines.Add('')
    }

    if ($JdkCandidates.Count -gt 0) {
        $lines.Add('JDK locations checked:')
        foreach ($item in $JdkCandidates) { $lines.Add(('  - {0}' -f $item)) }
        $lines.Add('')
    }

    $lines.Add('DETAILS:')
    $lines.Add(($ErrorRecord | Out-String).TrimEnd())

    Set-Content -LiteralPath $LogPath -Value $lines -Encoding UTF8
}

$jdkCandidates = @()

try {
    if (!(Test-Path -LiteralPath $LibRoot -PathType Container)) {
        throw "Application lib directory not found: $LibRoot"
    }

    $jdkResult = Find-JdkBin $JdkHome
    $jdkCandidates = @($jdkResult.Candidates)
    $jdkBin = $jdkResult.Bin

    if (!$jdkBin) {
        $checked = if ($jdkCandidates.Count) {
            "`nJDK locations checked:`n  - " + ($jdkCandidates -join "`n  - ")
        } else {
            "`nNo JDK candidate directory was found."
        }

        throw ("A full Windows JDK was not found. jdeps.exe and jlink.exe are required.`n" +
               "Install a 64-bit JDK 17 or newer, set JAVA_HOME/JDK_HOME, or run:`n" +
               "  BUILD-APPLICATION-RUNTIME.cmd -JdkHome `"C:\Path\To\Your\JDK`"" + $checked)
    }

    $jdeps = Join-Path $jdkBin 'jdeps.exe'
    $jlink = Join-Path $jdkBin 'jlink.exe'

    $versionOutput = @(& $jlink --version 2>&1)
    $versionCode = $LASTEXITCODE
    $versionText = ($versionOutput | Select-Object -First 1).ToString().Trim()
    if ($versionCode -ne 0) {
        throw "Could not read the selected JDK version. jlink returned exit code $versionCode. Output: $($versionOutput -join ' ')"
    }
    if ($versionText -notmatch '^(\d+)') {
        throw "Unexpected jlink version: $versionText"
    }

    $feature = [int]$Matches[1]
    if ($feature -lt 17) {
        throw "JDK $versionText is too old. Use JDK 17 or newer."
    }

    # SynKinect Studio V1 has one application JAR and one object model.
    $preferredJar = Join-Path $LibRoot 'SynKinectStudio.jar'
    Require-File $preferredJar 'SynKinectStudio.jar'
    $jar = Get-Item -LiteralPath $preferredJar

    Write-Host '============================================================' -ForegroundColor Cyan
    Write-Host ' SynKinect minimal Windows Java runtime' -ForegroundColor Cyan
    Write-Host '============================================================' -ForegroundColor Cyan
    Write-Host "JDK bin: $jdkBin"
    Write-Host "JDK version: $versionText"
    Write-Host "Representative application: $($jar.Name)"
    Write-Host ''

    $classPath = Join-Path $LibRoot '*'
    Write-Host ("Analyzing {0} with jdeps..." -f $jar.Name)

    $output = @(& $jdeps --multi-release $feature --ignore-missing-deps --recursive --print-module-deps --class-path $classPath $jar.FullName 2>&1)
    $jdepsCode = $LASTEXITCODE
    if ($jdepsCode -ne 0) {
        throw "jdeps failed for $($jar.Name) with exit code $jdepsCode.`n$($output -join [Environment]::NewLine)"
    }

    $line = $output |
        ForEach-Object { $_.ToString().Trim() } |
        Where-Object { $_ -match '^[A-Za-z0-9_.]+(?:,[A-Za-z0-9_.]+)*$' } |
        Select-Object -Last 1

    if (!$line) {
        throw "jdeps did not return a Java module list for $($jar.Name). Output:`n$($output -join [Environment]::NewLine)"
    }

    $modules = @(
        $line -split ',' |
            ForEach-Object { $_.Trim() } |
            Where-Object { $_ } |
            Sort-Object -Unique
    )

    Write-Host ("Modules: {0}" -f ($modules -join ',')) -ForegroundColor Green
    Write-Host ''

    if (Test-Path -LiteralPath $RuntimeRoot) {
        Write-Host "Removing previous runtime: $RuntimeRoot"
        Remove-Item -LiteralPath $RuntimeRoot -Recurse -Force
    }

    $compression = if ($feature -ge 21) { 'zip-6' } else { '2' }
    Write-Host "Creating runtime with jlink (compression=$compression)..."

    $jlinkOutput = @(& $jlink --add-modules ($modules -join ',') --strip-debug --no-header-files --no-man-pages "--compress=$compression" --output $RuntimeRoot 2>&1)
    $jlinkCode = $LASTEXITCODE
    if ($jlinkCode -ne 0) {
        throw "jlink failed with exit code $jlinkCode.`n$($jlinkOutput -join [Environment]::NewLine)"
    }

    Require-File (Join-Path $RuntimeRoot 'bin\java.exe')  'java.exe'
    Require-File (Join-Path $RuntimeRoot 'bin\javaw.exe') 'javaw.exe'

    $bytes = (Get-ChildItem -LiteralPath $RuntimeRoot -Recurse -File | Measure-Object Length -Sum).Sum
    $sizeMb = [Math]::Round($bytes / 1MB, 1)

    if (Test-Path -LiteralPath $LogPath -PathType Leaf) {
        Remove-Item -LiteralPath $LogPath -Force -ErrorAction SilentlyContinue
    }

    Write-Host ''
    Write-Host "Portable runtime created: $RuntimeRoot" -ForegroundColor Green
    Write-Host "Size: $sizeMb MB" -ForegroundColor Green
    Write-Host 'SynKinect Studio uses this single runtime for all five tabs.' -ForegroundColor Green
    exit 0
}
catch {
    try { Write-ErrorLog -ErrorRecord $_ -JdkCandidates $jdkCandidates } catch {}

    Write-Host ''
    Write-Host '============================================================' -ForegroundColor Red
    Write-Host ' BUILD FAILED' -ForegroundColor Red
    Write-Host '============================================================' -ForegroundColor Red
    Write-Host $_.Exception.Message -ForegroundColor Red
    Write-Host ''
    Write-Host "Error report: $LogPath" -ForegroundColor Yellow
    exit 1
}
