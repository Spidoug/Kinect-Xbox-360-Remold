function Write-BuildStage([string]$Message){
    Write-Host ("[{0}] {1}" -f (Get-Date -Format 'HH:mm:ss'),$Message) -ForegroundColor Cyan
}

function Require-File([string]$Path,[string]$What='File'){
    if(!(Test-Path -LiteralPath $Path -PathType Leaf)){throw "$What was not produced: $Path"}
}

function Write-Utf16Le([string]$Path,[string]$Text){
    [IO.File]::WriteAllText($Path,$Text,[Text.Encoding]::Unicode)
}

function Write-Utf8NoBom([string]$Path,[string]$Text){
    [IO.File]::WriteAllText($Path,$Text,(New-Object Text.UTF8Encoding($false)))
}

function Resolve-PinnedDependencyUrl([string]$Template,[string]$Commit,[string]$Label){
    if([string]::IsNullOrWhiteSpace($Template)){throw "Pinned dependency URL template is empty: $Label"}
    if($Commit -notmatch '^[0-9a-fA-F]{40}$'){throw "Pinned dependency commit is invalid while resolving URL: $Label"}
    $url=($Template -f $Commit)
    $uri=$null
    if(![Uri]::TryCreate($url,[UriKind]::Absolute,[ref]$uri) -or $uri.Scheme -ne 'https'){throw "Pinned dependency URL must be absolute HTTPS ($Label): $url"}
    return $url
}

function Get-PinnedDependency([hashtable]$Product,[string]$Name){
    if($null -eq $Product -or $null -eq $Product.Dependencies){throw 'Product.psd1 must define a Dependencies block.'}
    $dependency=$Product.Dependencies[$Name]
    if($null -eq $dependency){throw "Product.psd1 dependency '$Name' is not defined."}

    $kind=[string]($dependency.Kind)
    if([string]::IsNullOrWhiteSpace($kind)){throw "Product.psd1 dependency '$Name' must define Kind."}
    switch($kind){
        'GitArchive' {
            $commit=[string]$dependency.Commit
            if($commit -notmatch '^[0-9a-fA-F]{40}$'){throw "Product.psd1 Git dependency '$Name' must define a 40-character commit."}
            $repository=[string]$dependency.Repository
            $repositoryUri=$null
            if([string]::IsNullOrWhiteSpace($repository) -or ![Uri]::TryCreate($repository,[UriKind]::Absolute,[ref]$repositoryUri) -or $repositoryUri.Scheme -ne 'https'){
                throw "Product.psd1 Git dependency '$Name' must define an absolute HTTPS Repository."
            }
        }
        'HttpsArtifact' {
            $url=[string]($dependency.Url)
            $artifactUri=$null
            if([string]::IsNullOrWhiteSpace($url) -or ![Uri]::TryCreate($url,[UriKind]::Absolute,[ref]$artifactUri) -or $artifactUri.Scheme -ne 'https'){
                throw "Product.psd1 HTTPS artifact dependency '$Name' must define an absolute HTTPS Url."
            }
        }
        default { throw "Product.psd1 dependency '$Name' has unsupported Kind '$kind'." }
    }
    return ,$dependency
}

function Get-PinnedDependencyArchiveUrls([hashtable]$Product,[string]$Name){
    $dependency=Get-PinnedDependency $Product $Name
    if(([string]($dependency.Kind)) -ne 'GitArchive'){throw "Product.psd1 dependency '$Name' must be Kind=GitArchive for archive URLs."}
    $templates=@($dependency.ArchiveUrls)
    if($templates.Count -eq 0){throw "Product.psd1 dependency '$Name' must define ArchiveUrls."}
    $commit=[string]$dependency.Commit
    for($index=0;$index -lt $templates.Count;$index++){
        Resolve-PinnedDependencyUrl ([string]$templates[$index]) $commit ("$Name.ArchiveUrls[$index]")
    }
}

function Get-PinnedDependencyUrl([hashtable]$Product,[string]$Name,[string]$Property='UrlTemplate'){
    $dependency=Get-PinnedDependency $Product $Name
    if(([string]($dependency.Kind)) -ne 'GitArchive'){throw "Product.psd1 dependency '$Name' must be Kind=GitArchive for commit-templated URLs."}
    if(!$dependency.ContainsKey($Property)){throw "Product.psd1 dependency '$Name' must define $Property."}
    return Resolve-PinnedDependencyUrl ([string]$dependency[$Property]) ([string]$dependency.Commit) ("$Name.$Property")
}

function Get-CppUnsignedIntegerConstant([string]$Text,[string]$Name){
    if([string]::IsNullOrWhiteSpace($Text)-or[string]::IsNullOrWhiteSpace($Name)){throw 'C++ constant lookup requires source text and a name.'}
    $pattern=('(?im)\b'+[regex]::Escape($Name)+'\s*=\s*(0x[0-9a-f]+|[0-9]+)(?:u|ul|ull)?\b')
    $match=[regex]::Match($Text,$pattern)
    if(!$match.Success){throw "C++ unsigned integer constant '$Name' was not found."}
    $literal=$match.Groups[1].Value
    if($literal.StartsWith('0x',[StringComparison]::OrdinalIgnoreCase)){return [Convert]::ToUInt64($literal.Substring(2),16)}
    return [Convert]::ToUInt64($literal,10)
}

function Read-RequiredText([string]$Path,[string]$What='Text file'){
    Require-File $Path $What
    return [IO.File]::ReadAllText($Path)
}

function Replace-RequiredLiteral([string]$Text,[string]$Old,[string]$New,[string]$Label){
    if($null -eq $Text -or [string]::IsNullOrEmpty($Old)){throw "Text patch '$Label' requires source text and a non-empty literal."}
    $index=$Text.IndexOf($Old,[StringComparison]::Ordinal)
    if($index -lt 0){throw "Required text patch point is missing: $Label"}
    if($Text.IndexOf($Old,$index+$Old.Length,[StringComparison]::Ordinal) -ge 0){throw "Required text patch point is ambiguous: $Label"}
    return $Text.Substring(0,$index)+$New+$Text.Substring($index+$Old.Length)
}

function Replace-RequiredRegex([string]$Text,[string]$Pattern,[string]$Replacement,[string]$Label){
    if($null -eq $Text -or [string]::IsNullOrWhiteSpace($Pattern)){throw "Regex patch '$Label' requires source text and a pattern."}
    $regex=New-Object Text.RegularExpressions.Regex($Pattern,[Text.RegularExpressions.RegexOptions]::Singleline)
    $matches=$regex.Matches($Text)
    if($matches.Count -ne 1){throw "Required regex patch count for '$Label' is $($matches.Count), expected 1."}
    return $regex.Replace($Text,$Replacement,1)
}

function Get-GitCanonicalBlobSha1([string]$Path){
    Require-File $Path 'Git blob source'
    # Git hashes canonical LF text. GitHub archives may materialize CRLF according
    # to .gitattributes, so normalize CRLF before recreating the blob object.
    [byte[]]$raw=[IO.File]::ReadAllBytes($Path)
    $normalized=New-Object IO.MemoryStream
    try{
        for($i=0;$i -lt $raw.Length;$i++){
            if($raw[$i] -eq 13 -and ($i+1) -lt $raw.Length -and $raw[$i+1] -eq 10){continue}
            $normalized.WriteByte($raw[$i])
        }
        [byte[]]$data=$normalized.ToArray()
    }finally{$normalized.Dispose()}
    [byte[]]$prefix=[Text.Encoding]::ASCII.GetBytes(("blob {0}`0" -f $data.Length))
    [byte[]]$blob=New-Object byte[] ($prefix.Length+$data.Length)
    [Buffer]::BlockCopy($prefix,0,$blob,0,$prefix.Length)
    [Buffer]::BlockCopy($data,0,$blob,$prefix.Length,$data.Length)
    $sha=[Security.Cryptography.SHA1]::Create()
    try{return ([BitConverter]::ToString($sha.ComputeHash($blob))).Replace('-','').ToLowerInvariant()}finally{$sha.Dispose()}
}

function Assert-GitBlobSha1([string]$Path,[string]$Expected,[string]$Label){
    if($Expected -notmatch '^[0-9a-fA-F]{40}$'){throw "Invalid Git blob SHA-1 for '$Label'."}
    $actual=Get-GitCanonicalBlobSha1 $Path
    if($actual -ne $Expected.ToLowerInvariant()){throw "Unexpected source for $Label. Expected canonical Git blob $Expected, got $actual"}
}

function Stage-Inf([string]$Source,[string]$Destination,[hashtable]$Product){
    Require-File $Source 'Source INF'
    $text=[IO.File]::ReadAllText($Source)
    $line=('DriverVer   = {0},{1}' -f $Product.DriverDate,$Product.VersionQuad)
    $driverVerPattern=[regex]::new('(?im)^\s*DriverVer\s*=.*$')
    $updated=$driverVerPattern.Replace($text,$line,1)
    if($updated -eq $text -and $text -notmatch [regex]::Escape($line)){throw "DriverVer directive was not found in $Source"}
    Write-Utf16Le $Destination $updated
}

function Test-ZipArchive([string]$Path){
    if(!(Test-Path -LiteralPath $Path -PathType Leaf)){return $false}
    try{
        Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction SilentlyContinue
        $zip=[IO.Compression.ZipFile]::OpenRead($Path)
        try{return $zip.Entries.Count -gt 0}finally{$zip.Dispose()}
    }catch{return $false}
}

function Invoke-ResilientDownload(
    [string[]]$Urls,
    [string]$Destination,
    [switch]$ZipArchive,
    [ValidateRange(1,10)][int]$MaxAttempts=5
){
    if(!$Urls -or $Urls.Count -eq 0){throw 'At least one download URL is required.'}
    if(Test-Path -LiteralPath $Destination -PathType Leaf){
        if(!$ZipArchive -or (Test-ZipArchive $Destination)){
            Write-Host ("Using cached download: {0}" -f (Split-Path -Leaf $Destination)) -ForegroundColor DarkGray
            return
        }
        Write-Host ("Discarding invalid cached download: {0}" -f (Split-Path -Leaf $Destination)) -ForegroundColor Yellow
        Remove-Item -LiteralPath $Destination -Force -ErrorAction SilentlyContinue
    }

    $partial="$Destination.partial"
    $curl=Get-Command curl.exe -ErrorAction SilentlyContinue
    $lastError='no source attempted'
    foreach($url in $Urls){
        for($attempt=1;$attempt -le $MaxAttempts;$attempt++){
            try{
                Remove-Item -LiteralPath $partial -Force -ErrorAction SilentlyContinue
                Write-Host ("Download attempt {0}/{1}: {2}" -f $attempt,$MaxAttempts,$url) -ForegroundColor DarkGray
                if($curl){
                    & $curl.Source --fail --location --silent --show-error --connect-timeout 30 --retry 3 --retry-delay 2 --output $partial $url
                    if($LASTEXITCODE){throw "curl.exe failed with exit code $LASTEXITCODE"}
                }else{
                    Invoke-WebRequest -UseBasicParsing -Uri $url -OutFile $partial -TimeoutSec 120
                }
                Require-File $partial 'Downloaded file'
                if((Get-Item -LiteralPath $partial).Length -le 0){throw 'Downloaded file is empty.'}
                if($ZipArchive -and !(Test-ZipArchive $partial)){throw 'Downloaded file is not a valid ZIP archive.'}
                Move-Item -LiteralPath $partial -Destination $Destination -Force
                return
            }catch{
                $lastError=$_.Exception.Message
                Remove-Item -LiteralPath $partial -Force -ErrorAction SilentlyContinue
                if($attempt -lt $MaxAttempts){Start-Sleep -Seconds ([Math]::Min(2*$attempt,8))}
            }
        }
    }
    throw "Download failed after retries. $lastError"
}

function ConvertTo-WdkDriverTargetPlatform([string]$DriverTargetPlatform){
    if([string]::IsNullOrWhiteSpace($DriverTargetPlatform)){throw 'DriverTargetPlatform must be specified.'}
    $normalized=$DriverTargetPlatform.Trim().Replace(' ','').Replace('-','').ToLowerInvariant()
    switch($normalized){
        'desktop'       { return 'Desktop' }
        'universal'     { return 'Universal' }
        'windowsdriver' { return 'Windows Driver' }
        default { throw "Unsupported DriverTargetPlatform '$DriverTargetPlatform'. Expected Desktop, Universal, or WindowsDriver." }
    }
}

function Get-MsBuildConfigurationKey([string]$Condition){
    if([string]::IsNullOrWhiteSpace($Condition)){return ''}
    $match=[regex]::Match($Condition,'(?i)==\s*''([^'']+)''')
    if(!$match.Success){return ''}
    return $match.Groups[1].Value.Trim()
}

function Read-MsBuildProjectXml([string]$Path){
    Require-File $Path 'MSBuild project'
    $xml=New-Object System.Xml.XmlDocument
    $xml.PreserveWhitespace=$false
    # Downloaded dependency projects are input, not trusted XML configuration.
    # Disable external entity resolution before parsing and return the document as
    # one pipeline object even though XmlNode participates in enumeration.
    $xml.XmlResolver=$null
    $xml.Load($Path)
    return ,$xml
}

function Save-MsBuildProjectXml([System.Xml.XmlDocument]$Xml,[string]$Path){
    $settings=New-Object System.Xml.XmlWriterSettings
    $settings.Encoding=New-Object System.Text.UTF8Encoding($false)
    $settings.Indent=$true
    $settings.IndentChars='  '
    $settings.NewLineChars="`r`n"
    $settings.NewLineHandling=[System.Xml.NewLineHandling]::Replace
    $writer=[System.Xml.XmlWriter]::Create($Path,$settings)
    try{$Xml.Save($writer)}finally{$writer.Dispose()}
}

function Get-MsBuildNamespaceManager([System.Xml.XmlDocument]$Xml){
    if($null -eq $Xml -or $null -eq $Xml.DocumentElement -or $Xml.DocumentElement.LocalName -ne 'Project'){
        throw 'MSBuild XML must contain a Project document element.'
    }
    $namespaceUri=[string]$Xml.DocumentElement.NamespaceURI
    if([string]::IsNullOrWhiteSpace($namespaceUri)){throw 'MSBuild Project XML is missing its default namespace.'}
    $ns=New-Object System.Xml.XmlNamespaceManager($Xml.NameTable)
    $ns.AddNamespace('msb',$namespaceUri)
    # XmlNamespaceManager implements IEnumerable. A normal PowerShell return
    # enumerates it and turns the manager into namespace entries, which makes
    # SelectSingleNode(xpath, namespaceManager) fail at runtime. Unary comma is
    # therefore part of this helper's contract and must not be removed.
    return ,$ns
}


function Resolve-MsBuildRuntimeLibraryPolicyValue([hashtable]$Policy,[string]$Configuration){
    if($null -eq $Policy -or $Policy.Count -eq 0){throw 'MSBuild runtime-library policy must define at least one configuration.'}
    if([string]::IsNullOrWhiteSpace($Configuration)){return ''}
    foreach($key in @($Policy.Keys)){
        if(![string]::Equals([string]$key,$Configuration,[StringComparison]::OrdinalIgnoreCase)){continue}
        $value=[string]$Policy[$key]
        if($value -notin @('MultiThreaded','MultiThreadedDebug','MultiThreadedDLL','MultiThreadedDebugDLL')){
            throw "Unsupported MSBuild RuntimeLibrary value '$value' for configuration '$Configuration'."
        }
        return $value
    }
    return ''
}

function Assert-MsBuildRuntimeLibraryPolicy([string]$Path,[hashtable]$Policy){
    if($null -eq $Policy -or $Policy.Count -eq 0){throw 'MSBuild runtime-library policy must define at least one configuration.'}
    $xml=Read-MsBuildProjectXml $Path
    $ns=Get-MsBuildNamespaceManager $xml
    $groups=@($xml.SelectNodes('/msb:Project/msb:ItemDefinitionGroup[msb:ClCompile]',$ns))
    if($groups.Count -eq 0){throw "MSBuild project has no ClCompile item-definition groups: $Path"}

    $seen=@{}
    $validated=0
    foreach($group in $groups){
        $key=Get-MsBuildConfigurationKey ([string]$group.GetAttribute('Condition'))
        if([string]::IsNullOrWhiteSpace($key)){continue}
        $separator=$key.IndexOf('|')
        $configuration=if($separator -ge 0){$key.Substring(0,$separator).Trim()}else{$key.Trim()}
        $expected=Resolve-MsBuildRuntimeLibraryPolicyValue $Policy $configuration
        if([string]::IsNullOrWhiteSpace($expected)){continue}

        $compile=$group.SelectSingleNode('msb:ClCompile',$ns)
        $runtime=$compile.SelectSingleNode('msb:RuntimeLibrary',$ns)
        if(!$runtime){throw "MSBuild RuntimeLibrary is missing for '$key' in $Path"}
        $actual=[string]$runtime.InnerText
        if($actual.Trim() -ne $expected){throw "MSBuild RuntimeLibrary mismatch for '$key': expected '$expected', got '$actual' in $Path"}
        $seen[$configuration]=$true
        $validated++
    }

    foreach($configuration in @($Policy.Keys)){
        if(!$seen.ContainsKey([string]$configuration)){throw "MSBuild runtime-library policy configuration '$configuration' was not found in $Path"}
    }
    Write-Host ("MSBuild runtime policy: PASS ({0}, groups={1})" -f (Split-Path -Leaf $Path),$validated) -ForegroundColor Green
}

function Set-MsBuildRuntimeLibraryPolicy([string]$Path,[hashtable]$Policy){
    if($null -eq $Policy -or $Policy.Count -eq 0){throw 'MSBuild runtime-library policy must define at least one configuration.'}
    $xml=Read-MsBuildProjectXml $Path
    $ns=Get-MsBuildNamespaceManager $xml
    $root=$xml.DocumentElement
    $groups=@($xml.SelectNodes('/msb:Project/msb:ItemDefinitionGroup[msb:ClCompile]',$ns))
    if($groups.Count -eq 0){throw "MSBuild project has no ClCompile item-definition groups to normalize: $Path"}

    $seen=@{}
    $updated=0
    foreach($group in $groups){
        $key=Get-MsBuildConfigurationKey ([string]$group.GetAttribute('Condition'))
        if([string]::IsNullOrWhiteSpace($key)){continue}
        $separator=$key.IndexOf('|')
        $configuration=if($separator -ge 0){$key.Substring(0,$separator).Trim()}else{$key.Trim()}
        $expected=Resolve-MsBuildRuntimeLibraryPolicyValue $Policy $configuration
        if([string]::IsNullOrWhiteSpace($expected)){continue}

        $compile=$group.SelectSingleNode('msb:ClCompile',$ns)
        $runtime=$compile.SelectSingleNode('msb:RuntimeLibrary',$ns)
        if(!$runtime){
            $runtime=$xml.CreateElement('RuntimeLibrary',$root.NamespaceURI)
            $compile.AppendChild($runtime)|Out-Null
        }
        $runtime.InnerText=$expected
        $seen[$configuration]=$true
        $updated++
    }

    foreach($configuration in @($Policy.Keys)){
        if(!$seen.ContainsKey([string]$configuration)){throw "MSBuild runtime-library policy configuration '$configuration' was not found while normalizing $Path"}
    }

    Save-MsBuildProjectXml $xml $Path
    Assert-MsBuildRuntimeLibraryPolicy $Path $Policy
    Write-Host ("MSBuild runtime normalization: PASS ({0}, groups={1})" -f (Split-Path -Leaf $Path),$updated) -ForegroundColor Green
}

function Assert-WdkProjectContract(
    [string]$Path,
    [ValidateSet('Driver','StaticLibrary')][string]$ConfigurationType,
    [string]$DriverType='KMDF',
    [string]$RequiredInf='',
    [string]$DriverTargetPlatform=''
){
    $expectedDriverTarget=if([string]::IsNullOrWhiteSpace($DriverTargetPlatform)){''}else{ConvertTo-WdkDriverTargetPlatform $DriverTargetPlatform}
    $xml=Read-MsBuildProjectXml $Path
    $ns=Get-MsBuildNamespaceManager $xml
    $root=$xml.DocumentElement
    $children=@($root.ChildNodes)
    $defaultProps=$xml.SelectSingleNode('/msb:Project/msb:Import[contains(@Project,"Microsoft.Cpp.Default.props")]',$ns)
    $cppProps=$xml.SelectSingleNode('/msb:Project/msb:Import[contains(@Project,"Microsoft.Cpp.props") and not(contains(@Project,"Default"))]',$ns)
    if(!$defaultProps -or !$cppProps){throw "WDK project is missing the C++ props import chain: $Path"}
    $defaultIndex=[Array]::IndexOf($children,$defaultProps)
    $cppIndex=[Array]::IndexOf($children,$cppProps)
    if($defaultIndex -lt 0 -or $cppIndex -le $defaultIndex){throw "WDK project C++ props import order is invalid: $Path"}

    $preDefaultToolset=@($children[0..([Math]::Max(0,$defaultIndex-1))] | Where-Object{
        $_.NodeType -eq [System.Xml.XmlNodeType]::Element -and $_.LocalName -eq 'PropertyGroup' -and $_.SelectSingleNode('msb:PlatformToolset',$ns)
    })
    if($preDefaultToolset.Count -gt 0){throw "WDK PlatformToolset is defined before Microsoft.Cpp.Default.props and can be ignored by modern MSBuild: $Path"}

    $projectConfigs=@($xml.SelectNodes('/msb:Project/msb:ItemGroup[@Label="ProjectConfigurations"]/msb:ProjectConfiguration',$ns))
    if($projectConfigs.Count -eq 0){throw "WDK project has no ProjectConfigurations: $Path"}
    $configGroups=@($xml.SelectNodes('/msb:Project/msb:PropertyGroup[@Label="Configuration" and @Condition]',$ns))
    foreach($projectConfig in $projectConfigs){
        $key=[string]$projectConfig.Include
        $matches=@($configGroups|Where-Object{(Get-MsBuildConfigurationKey ([string]$_.Condition)) -eq $key})
        if($matches.Count -ne 1){throw "WDK project must have exactly one Configuration property group for '$key': $Path"}
        $group=$matches[0]
        $groupIndex=[Array]::IndexOf($children,$group)
        if($groupIndex -le $defaultIndex -or $groupIndex -ge $cppIndex){throw "WDK Configuration '$key' must be between Microsoft.Cpp.Default.props and Microsoft.Cpp.props: $Path"}
        $required=[ordered]@{
            PlatformToolset='WindowsKernelModeDriver10.0'
            ConfigurationType=$ConfigurationType
        }
        if(![string]::IsNullOrWhiteSpace($DriverType)){$required['DriverType']=$DriverType}
        foreach($name in $required.Keys){
            $node=$group.SelectSingleNode("msb:$name",$ns)
            if(!$node -or $node.InnerText.Trim() -ne [string]$required[$name]){
                throw "WDK Configuration '$key' must define $name=$($required[$name]): $Path"
            }
        }
        $targetPlatform=$group.SelectSingleNode('msb:DriverTargetPlatform',$ns)
        if(!$targetPlatform){throw "WDK Configuration '$key' must declare DriverTargetPlatform: $Path"}
        $actualDriverTarget=ConvertTo-WdkDriverTargetPlatform $targetPlatform.InnerText.Trim()
        if(![string]::IsNullOrWhiteSpace($expectedDriverTarget) -and $actualDriverTarget -ne $expectedDriverTarget){
            throw "WDK Configuration '$key' DriverTargetPlatform mismatch: expected '$expectedDriverTarget', got '$actualDriverTarget' in $Path"
        }
    }
    if(![string]::IsNullOrWhiteSpace($RequiredInf)){
        $infNodes=@($xml.SelectNodes('/msb:Project/msb:ItemGroup/msb:Inf',$ns)|Where-Object{[string]$_.Include -ieq $RequiredInf})
        if($infNodes.Count -ne 1){throw "WDK project contract missing INF item '$RequiredInf': $Path"}
    }
    $platformLabel=if([string]::IsNullOrWhiteSpace($expectedDriverTarget)){'supported'}else{$expectedDriverTarget}
    Write-Host ("WDK project contract: PASS ({0}, configurations={1}, type={2}, platform={3}, toolset=WindowsKernelModeDriver10.0)" -f (Split-Path -Leaf $Path),$projectConfigs.Count,$ConfigurationType,$platformLabel) -ForegroundColor Green
}


function Assert-MsBuildWdkEvaluation(
    [string]$Path,
    [object]$Tools,
    [string]$Configuration,
    [ValidateSet('Driver','StaticLibrary')][string]$ConfigurationType,
    [string]$DriverType='KMDF',
    [string]$DriverTargetPlatform=''
){
    $expectedDriverTarget=if([string]::IsNullOrWhiteSpace($DriverTargetPlatform)){''}else{ConvertTo-WdkDriverTargetPlatform $DriverTargetPlatform}
    Require-File $Path 'WDK project'
    $query='-getProperty:PlatformToolset,ConfigurationType,DriverType,DriverTargetPlatform,WDKContentRoot,WindowsTargetPlatformVersion,TargetPlatformVersion,TargetPlatformVersion_CO,MatchingWdkPresent'
    $wdkCliRoot=[string]$Tools.WdkMsBuildRoot
    if([string]::IsNullOrWhiteSpace($wdkCliRoot)){throw "Toolchain did not provide WdkMsBuildRoot for safe native MSBuild invocation: $Path"}
    if($wdkCliRoot.EndsWith('\')){throw "Unsafe MSBuild WDKContentRoot argument ends in backslash: '$wdkCliRoot'"}
    $wdkRootArg="/p:WDKContentRoot=$wdkCliRoot"
    $windowsTargetArg="/p:WindowsTargetPlatformVersion=$($Tools.WdkVersion)"
    $targetPlatformArg="/p:TargetPlatformVersion=$($Tools.WdkVersion)"
    $raw=@(& $Tools.MSBuild $Path /nologo /p:Configuration=$Configuration /p:Platform=x64 /p:TargetVersion=Windows10 $windowsTargetArg $targetPlatformArg $wdkRootArg $query 2>&1)
    if($LASTEXITCODE){throw "MSBuild WDK evaluation failed for $Path`n$($raw -join "`n")"}
    $json=($raw -join "`n").Trim()
    try{$evaluation=$json|ConvertFrom-Json -ErrorAction Stop}catch{throw "MSBuild WDK evaluation did not return valid JSON for $Path`n$json"}
    $props=$evaluation.Properties
    if(!$props){throw "MSBuild WDK evaluation returned no Properties object: $Path"}
    $required=[ordered]@{
        PlatformToolset='WindowsKernelModeDriver10.0'
        ConfigurationType=$ConfigurationType
    }
    if(![string]::IsNullOrWhiteSpace($DriverType)){$required['DriverType']=$DriverType}
    foreach($name in $required.Keys){
        $actual=[string]$props.$name
        if($actual.Trim() -ne [string]$required[$name]){throw "Effective MSBuild property mismatch for ${name}: expected '$($required[$name])', got '$actual' in $Path"}
    }
    $targetPlatform=[string]$props.DriverTargetPlatform
    $actualDriverTarget=ConvertTo-WdkDriverTargetPlatform $targetPlatform.Trim()
    if(![string]::IsNullOrWhiteSpace($expectedDriverTarget) -and $actualDriverTarget -ne $expectedDriverTarget){throw "Effective DriverTargetPlatform mismatch: expected '$expectedDriverTarget', got '$actualDriverTarget' in $Path"}
    $wdkRoot=[string]$props.WDKContentRoot
    if([string]::IsNullOrWhiteSpace($wdkRoot)){throw "WDK platform props were not imported (WDKContentRoot is empty): $Path"}
    $effectiveWdkRoot=[IO.Path]::GetFullPath($wdkRoot).TrimEnd('\')
    $expectedWdkRoot=[IO.Path]::GetFullPath([string]$Tools.WdkRoot).TrimEnd('\')
    if(![string]::Equals($effectiveWdkRoot,$expectedWdkRoot,[StringComparison]::OrdinalIgnoreCase)){
        throw "Effective WDKContentRoot mismatch: expected '$expectedWdkRoot', got '$effectiveWdkRoot' in $Path"
    }
    $windowsTarget=[string]$props.WindowsTargetPlatformVersion
    $targetPlatformVersion=[string]$props.TargetPlatformVersion
    if($windowsTarget.Trim() -ne [string]$Tools.WdkVersion){throw "Effective WindowsTargetPlatformVersion mismatch: expected '$($Tools.WdkVersion)', got '$windowsTarget' in $Path"}
    if($targetPlatformVersion.Trim() -ne [string]$Tools.WdkVersion){throw "Effective TargetPlatformVersion mismatch: expected '$($Tools.WdkVersion)', got '$targetPlatformVersion' in $Path"}
    if([string]::IsNullOrWhiteSpace([string]$props.TargetPlatformVersion_CO)){throw "WDK default properties were not fully imported (TargetPlatformVersion_CO is empty): $Path"}
    if(![string]::Equals(([string]$props.MatchingWdkPresent).Trim(),'true',[StringComparison]::OrdinalIgnoreCase)){throw "Selected WDK version is not visible to the WDK property chain (MatchingWdkPresent='$($props.MatchingWdkPresent)'): $Path"}
    $expectedNtDdk=Join-Path $expectedWdkRoot "Include\$($Tools.WdkVersion)\km\ntddk.h"
    Require-File $expectedNtDdk 'Selected WDK ntddk.h'
    Write-Host ("MSBuild WDK evaluation: PASS ({0}, toolset={1}, platform={2}, WDK={3}, version={4})" -f (Split-Path -Leaf $Path),$props.PlatformToolset,$actualDriverTarget,$effectiveWdkRoot,$Tools.WdkVersion) -ForegroundColor Green
}

function Assert-NoExternalVcRuntime([string]$Binary,[object]$Tools){
    Require-File $Binary 'Native binary'
    $lines=@(& $Tools.DumpBin /nologo /dependents $Binary 2>&1)
    if($LASTEXITCODE){throw "dumpbin failed for $Binary"}
    $text=$lines -join "`n"
    $bad=[regex]::Matches($text,'(?im)^\s*((?:VCRUNTIME|MSVCP|CONCRT)[^\s]*\.DLL)\s*$') |
        ForEach-Object{$_.Groups[1].Value.ToUpperInvariant()} | Select-Object -Unique
    if($bad){throw "External Visual C++ runtime dependency remains in $Binary : $($bad -join ', ')"}
}

function Get-InfCatalogName([string]$InfPath){
    Require-File $InfPath 'INF'
    $text=[IO.File]::ReadAllText($InfPath)
    $match=[regex]::Match($text,'(?im)^\s*CatalogFile(?:\.[^=\s]+)?\s*=\s*([^\s;]+)\s*$')
    if(!$match.Success){throw "CatalogFile directive is missing in $InfPath"}
    return $match.Groups[1].Value.Trim()
}

function Get-InfVerifMode([string]$DriverTargetPlatform){
    switch(ConvertTo-WdkDriverTargetPlatform $DriverTargetPlatform){
        'Desktop'        { return 'h' }
        'Universal'      { return 'u' }
        'Windows Driver' { return 'w' }
        default { throw "Unsupported DriverTargetPlatform '$DriverTargetPlatform'." }
    }
}

function Get-Inf2CatSupportedOsTargets([string]$Inf2Cat,[string[]]$Requested){
    if(!$Requested -or $Requested.Count -eq 0){throw 'At least one Inf2Cat OS target is required.'}
    if([string]::IsNullOrWhiteSpace($script:RemoldInf2CatHelp)){
        $script:RemoldInf2CatHelp=(@(& $Inf2Cat /? 2>&1) -join "`n")
    }
    $supported=@()
    foreach($target in $Requested){
        if([regex]::IsMatch($script:RemoldInf2CatHelp,('(?i)(^|[^A-Z0-9_]){0}([^A-Z0-9_]|$)' -f [regex]::Escape($target)))){
            $supported += $target
        }
    }
    if($supported.Count -eq 0){
        throw "Installed Inf2Cat does not advertise any requested x64 Windows target: $($Requested -join ', '). Install/update the Windows Driver Kit."
    }
    $skipped=@($Requested|Where-Object{$_ -notin $supported})
    if($skipped.Count -gt 0){
        Write-Host ("Inf2Cat: skipping targets not supported by this WDK: {0}" -f ($skipped -join ', ')) -ForegroundColor Yellow
    }
    return @($supported)
}

function Build-PackageCatalog([string]$Package,[string]$Inf,[object]$Tools,[string[]]$OsTargets,[string]$DriverTargetPlatform){
    $path=Join-Path $Package $Inf
    Require-File $path 'Staged INF'
    $text=[IO.File]::ReadAllText($path)
    if($text -notmatch '(?im)^\s*\[Version\]\s*$'){throw "Package INF validation failed for ${Inf}: missing [Version]"}
    if($text -notmatch '(?im)^\s*Signature\s*=\s*"\$Windows NT\$"\s*$'){throw "Package INF validation failed for ${Inf}: invalid Signature directive"}
    foreach($directive in @('Class','ClassGuid','Provider','DriverVer','CatalogFile')){
        if($text -notmatch ('(?im)^\s*{0}\s*=\s*\S.+' -f [regex]::Escape($directive))){throw "Package INF validation failed for ${Inf}: missing $directive directive"}
    }
    if($text -match '(?i)TODO-Set-Provider|REPLACE_ME'){throw "Package INF validation failed for ${Inf}: placeholder text remains"}
    if($path.Length -ge 260){throw "INF path is too long for InfVerif ($($path.Length) characters): $path"}
    $cat=Get-InfCatalogName $path
    $infVerifMode=Get-InfVerifMode $DriverTargetPlatform
    & $Tools.InfVerif ("/{0}" -f $infVerifMode) /v $path
    if($LASTEXITCODE){throw "InfVerif /$infVerifMode failed for $Inf (DriverTargetPlatform=$DriverTargetPlatform)"}
    $effectiveOsTargets=Get-Inf2CatSupportedOsTargets $Tools.Inf2Cat $OsTargets
    $osArgument='/os:' + ($effectiveOsTargets -join ',')
    & $Tools.Inf2Cat "/driver:$Package" $osArgument '/uselocaltime'
    if($LASTEXITCODE){throw "Inf2Cat failed for $Inf"}
    Require-File (Join-Path $Package $cat) $cat
    Write-Host ("Catalog generation: PASS ({0} -> {1}, InfVerif /{2}, OS={3})" -f $Inf,$cat,$infVerifMode,($effectiveOsTargets -join ',')) -ForegroundColor Green
}

function Get-DefaultLogPath([string]$Root,[string]$Prefix='build'){
    $dir=Join-Path $Root 'logs'
    New-Item -ItemType Directory -Force $dir|Out-Null
    return Join-Path $dir (("{0}-{1}.log" -f $Prefix,(Get-Date -Format 'yyyyMMdd-HHmmss')))
}

function Remove-NativeBuildOutputs([string]$Root,[string[]]$GeneratedRoots){
    foreach($path in $GeneratedRoots){Remove-Item -LiteralPath $path -Recurse -Force -ErrorAction SilentlyContinue}
    $source=Join-Path $Root 'source'
    if(Test-Path -LiteralPath $source -PathType Container){
        Get-ChildItem -LiteralPath $source -Recurse -Directory -ErrorAction SilentlyContinue |
            Where-Object{$_.Name -in @('x64','Debug','Release')} | Sort-Object FullName -Descending |
            ForEach-Object{Remove-Item -LiteralPath $_.FullName -Recurse -Force -ErrorAction SilentlyContinue}
    }
}

function Find-LatestBuildArtifact([string]$Root,[string]$Filter,[string]$What=$Filter){
    $item=Get-ChildItem -LiteralPath $Root -Recurse -File -Filter $Filter -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if(!$item){throw "$What not found after build."}
    return $item
}

function Assert-PackageContents([string]$Path,[string[]]$ExpectedFiles){
    $actual=@(Get-ChildItem -LiteralPath $Path -File|Select-Object -ExpandProperty Name|Sort-Object)
    $want=@($ExpectedFiles|Sort-Object)
    $missing=@($want|Where-Object{$_ -notin $actual})
    $extra=@($actual|Where-Object{$_ -notin $want})
    if($missing){throw "Missing files in ${Path}: $($missing -join ', ')"}
    if($extra){throw "Unexpected files in ${Path}: $($extra -join ', ')"}
}

function Get-OrCreateDevelopmentCertificate([hashtable]$Product,[string]$Thumbprint=''){
    $subject=[string]$Product.DevelopmentCertificateSubject
    $now=Get-Date
    $cert=$null
    if(![string]::IsNullOrWhiteSpace($Thumbprint)){
        $normalized=($Thumbprint -replace '\s','').ToUpperInvariant()
        $cert=Get-ChildItem Cert:\CurrentUser\My -ErrorAction SilentlyContinue |
            Where-Object{$_.Thumbprint.ToUpperInvariant() -eq $normalized} | Select-Object -First 1
        if(!$cert){throw "Development signing certificate $normalized was not found in Cert:\CurrentUser\My."}
        if($cert.Subject -ne $subject){throw "Development signing certificate subject mismatch: $($cert.Subject)"}
    }else{
        $cert=Get-ChildItem Cert:\CurrentUser\My -ErrorAction SilentlyContinue |
            Where-Object{$_.Subject -eq $subject -and $_.HasPrivateKey -and $_.NotAfter -gt $now.AddDays(30)} |
            Sort-Object NotAfter -Descending | Select-Object -First 1
        if(!$cert){
            if(!(Get-Command New-SelfSignedCertificate -ErrorAction SilentlyContinue)){throw 'New-SelfSignedCertificate is required to create the development package certificate.'}
            $cert=New-SelfSignedCertificate -Type CodeSigningCert -Subject $subject -CertStoreLocation 'Cert:\CurrentUser\My' -KeyAlgorithm RSA -KeyLength 2048 -HashAlgorithm SHA256 -KeyExportPolicy Exportable -NotAfter $now.AddYears(3)
        }
    }
    if(!$cert -or !$cert.HasPrivateKey){throw 'Development code-signing certificate is unavailable or has no private key.'}
    if($cert.NotAfter -le $now){throw 'Development code-signing certificate is expired.'}
    return $cert
}

function Sign-CodeArtifact([string]$Path,[object]$Certificate,[object]$Tools,[string]$Label='code artifact'){
    Require-File $Path $Label
    if(!$Tools.SignTool){throw 'SignTool.exe is required for development signing.'}
    & $Tools.SignTool sign /fd SHA256 /sha1 $Certificate.Thumbprint $Path
    if($LASTEXITCODE){throw "SignTool failed for ${Label}: $Path"}
    $sig=Get-AuthenticodeSignature -LiteralPath $Path
    if($null -eq $sig.SignerCertificate -or $sig.SignerCertificate.Thumbprint.ToUpperInvariant() -ne $Certificate.Thumbprint.ToUpperInvariant()){
        throw "Signer mismatch after signing ${Label}: $Path"
    }
    if($sig.Status -eq [System.Management.Automation.SignatureStatus]::HashMismatch){throw "Signature hash mismatch after signing ${Label}: $Path"}
}

