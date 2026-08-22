function Import-RemoldProductConfig([string]$ScriptRoot){
    $candidates=@(
        (Join-Path $ScriptRoot 'Product.psd1'),
        (Join-Path (Split-Path -Parent $ScriptRoot) 'build\Product.psd1')
    )
    foreach($candidate in $candidates){
        if(Test-Path -LiteralPath $candidate -PathType Leaf){return Import-PowerShellDataFile $candidate}
    }
    throw 'Product.psd1 was not found next to the installer or in the source build directory.'
}

function Test-IsAdministrator{
    $identity=[Security.Principal.WindowsIdentity]::GetCurrent()
    $principal=New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Require-Administrator([string]$Message='Administrator privileges are required.'){
    if(!(Test-IsAdministrator)){throw $Message}
}

function ConvertTo-NativeArgument([AllowEmptyString()][string]$Value){
    if($null -eq $Value -or $Value.Length -eq 0){return '""'}
    if($Value -notmatch '[\s"]'){return $Value}
    $escaped=[regex]::Replace($Value,'(\\*)"','$1$1\"')
    $escaped=[regex]::Replace($escaped,'(\\+)$','$1$1')
    return '"'+$escaped+'"'
}

function Split-NativeText([string]$Text){
    if([string]::IsNullOrWhiteSpace($Text)){return @()}
    return @($Text -split '\r?\n'|Where-Object{$_.Length -gt 0})
}

function Invoke-Native([string]$FilePath,[string[]]$Arguments=@()){
    $psi=New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName=$FilePath
    $psi.Arguments=(($Arguments|ForEach-Object{ConvertTo-NativeArgument ([string]$_)}) -join ' ')
    $psi.UseShellExecute=$false
    $psi.CreateNoWindow=$true
    $psi.RedirectStandardOutput=$true
    $psi.RedirectStandardError=$true
    $process=New-Object System.Diagnostics.Process
    $process.StartInfo=$psi
    try{
        if(!$process.Start()){throw ("Could not start native program: {0}" -f $FilePath)}
        $stdoutTask=$process.StandardOutput.ReadToEndAsync()
        $stderrTask=$process.StandardError.ReadToEndAsync()
        $process.WaitForExit()
        $out=[string]$stdoutTask.Result
        $err=[string]$stderrTask.Result
        $outLines=@(Split-NativeText $out)
        $errLines=@(Split-NativeText $err)
        return [pscustomobject]@{
            ExitCode=[int]$process.ExitCode
            StdOut=$out
            StdErr=$err
            StdOutLines=$outLines
            StdErrLines=$errLines
            Lines=@($outLines+$errLines)
        }
    }finally{$process.Dispose()}
}

function Show-Native($Result){
    if($null -ne $Result -and $Result.Lines.Count){$Result.Lines|ForEach-Object{Write-Host $_}}
}

function Invoke-NativeCode([string]$FilePath,[string[]]$Arguments=@(),[switch]$Show){
    $result=Invoke-Native $FilePath $Arguments
    if($Show){Show-Native $result}
    return [int]$result.ExitCode
}

function Get-CertificateFromFile([string]$Path){
    return New-Object System.Security.Cryptography.X509Certificates.X509Certificate2($Path)
}

function Add-CertificateToMachineStore([System.Security.Cryptography.X509Certificates.X509Certificate2]$Certificate,[string]$StoreName){
    $store=New-Object System.Security.Cryptography.X509Certificates.X509Store($StoreName,[System.Security.Cryptography.X509Certificates.StoreLocation]::LocalMachine)
    try{
        $store.Open([System.Security.Cryptography.X509Certificates.OpenFlags]::ReadWrite)
        if(!($store.Certificates|Where-Object{$_.Thumbprint -eq $Certificate.Thumbprint}|Select-Object -First 1)){$store.Add($Certificate)}
    }finally{$store.Close()}
}

function Remove-CertificateFromMachineStore([System.Security.Cryptography.X509Certificates.X509Certificate2]$Certificate,[string]$StoreName){
    $store=New-Object System.Security.Cryptography.X509Certificates.X509Store($StoreName,[System.Security.Cryptography.X509Certificates.StoreLocation]::LocalMachine)
    try{
        $store.Open([System.Security.Cryptography.X509Certificates.OpenFlags]::ReadWrite)
        @($store.Certificates|Where-Object{$_.Thumbprint -eq $Certificate.Thumbprint})|ForEach-Object{$store.Remove($_)}
    }finally{$store.Close()}
}

function Get-DistributionArtifact([string]$Root,[string]$RelativePath){
    return Join-Path $Root $RelativePath
}
