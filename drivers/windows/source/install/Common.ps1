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



function Get-ServiceProcessId([string]$Name){
    try{
        $escaped=$Name.Replace("'","''")
        $service=Get-CimInstance Win32_Service -Filter ("Name='{0}'" -f $escaped) -ErrorAction Stop
        if($null -eq $service){return 0}
        return [int]$service.ProcessId
    }catch{return 0}
}

function Test-ServiceStopped([string]$Name){
    $service=Get-Service -Name $Name -ErrorAction SilentlyContinue
    return ($null -eq $service -or $service.Status -eq [System.ServiceProcess.ServiceControllerStatus]::Stopped)
}

function Wait-ServiceStopped([string]$Name,[int]$TimeoutMs=5000){
    $deadline=[DateTime]::UtcNow.AddMilliseconds([Math]::Max(0,$TimeoutMs))
    do{
        if(Test-ServiceStopped $Name){return $true}
        Start-Sleep -Milliseconds 150
    }while([DateTime]::UtcNow -lt $deadline)
    return (Test-ServiceStopped $Name)
}

function Stop-ServiceBounded([string]$Name,[int]$TimeoutMs=5000,[switch]$ForceProcess,[switch]$Quiet){
    if([string]::IsNullOrWhiteSpace($Name)){return $true}
    $service=Get-Service -Name $Name -ErrorAction SilentlyContinue
    if($null -eq $service -or $service.Status -eq [System.ServiceProcess.ServiceControllerStatus]::Stopped){return $true}

    # Avoid Stop-Service here. ServiceController can wait indefinitely while a
    # broken service remains STOP_PENDING. sc.exe only submits the control; the
    # bounded polling below is owned by the Remold installer.
    [void](Invoke-Native 'sc.exe' @('stop',$Name))
    if(Wait-ServiceStopped $Name $TimeoutMs){return $true}

    if($ForceProcess){
        $servicePid=Get-ServiceProcessId $Name
        if($servicePid -gt 0){
            if(!$Quiet){Write-Warning ("Service {0} did not stop in {1} ms; terminating service process PID {2}." -f $Name,$TimeoutMs,$servicePid)}
            [void](Invoke-Native 'taskkill.exe' @('/PID',[string]$servicePid,'/T','/F'))
            if(Wait-ServiceStopped $Name 3500){return $true}
            # SCM status can lag process death briefly. One more query/poll is
            # cheap and prevents false reboot requests after a successful kill.
            Start-Sleep -Milliseconds 300
            if(Wait-ServiceStopped $Name 1500){return $true}
        }
    }

    if(!$Quiet){Write-Warning ("Service {0} is still not stopped after bounded shutdown." -f $Name)}
    return $false
}

function Start-ServiceBounded([string]$Name,[int]$TimeoutMs=7000,[switch]$Quiet){
    if([string]::IsNullOrWhiteSpace($Name)){return $false}
    $service=Get-Service -Name $Name -ErrorAction SilentlyContinue
    if($null -eq $service){return $false}
    if($service.Status -eq [System.ServiceProcess.ServiceControllerStatus]::Running){return $true}
    [void](Invoke-Native 'sc.exe' @('start',$Name))
    $deadline=[DateTime]::UtcNow.AddMilliseconds([Math]::Max(0,$TimeoutMs))
    do{
        $fresh=Get-Service -Name $Name -ErrorAction SilentlyContinue
        if($null -eq $fresh){return $false}
        if($fresh.Status -eq [System.ServiceProcess.ServiceControllerStatus]::Running){return $true}
        if($fresh.Status -eq [System.ServiceProcess.ServiceControllerStatus]::Stopped){
            # Give SCM a small grace period: a freshly updated service can
            # briefly report STOPPED before its start request is dispatched.
        }
        Start-Sleep -Milliseconds 150
    }while([DateTime]::UtcNow -lt $deadline)
    if(!$Quiet){Write-Warning ("Service {0} did not reach RUNNING within {1} ms." -f $Name,$TimeoutMs)}
    return $false
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
