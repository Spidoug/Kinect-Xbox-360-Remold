param(
    [Parameter(Mandatory=$true)][string]$MsiPath,
    [Parameter(Mandatory=$true)][string]$OutputPath,
    [Parameter(Mandatory=$true)][string]$ExpectedName
)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest

if(!(Test-Path -LiteralPath $MsiPath -PathType Leaf)){throw "MSI not found: $MsiPath"}
if([string]::IsNullOrWhiteSpace($ExpectedName)){throw 'ExpectedName is empty.'}

$native=@'
using System;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;

public static class RemoldMsiNative
{
    private const uint ERROR_SUCCESS = 0;
    private const uint ERROR_NO_MORE_ITEMS = 259;

    [DllImport("msi.dll", CharSet = CharSet.Unicode, EntryPoint = "MsiOpenDatabaseW")]
    private static extern uint MsiOpenDatabase(string databasePath, IntPtr persist, out uint database);

    [DllImport("msi.dll", CharSet = CharSet.Unicode, EntryPoint = "MsiDatabaseOpenViewW")]
    private static extern uint MsiDatabaseOpenView(uint database, string query, out uint view);

    [DllImport("msi.dll")]
    private static extern uint MsiViewExecute(uint view, uint record);

    [DllImport("msi.dll")]
    private static extern uint MsiViewFetch(uint view, out uint record);

    [DllImport("msi.dll", CharSet = CharSet.Unicode, EntryPoint = "MsiRecordGetStringW")]
    private static extern uint MsiRecordGetString(uint record, uint field, StringBuilder value, ref uint valueChars);

    [DllImport("msi.dll")]
    private static extern uint MsiRecordReadStream(uint record, uint field, byte[] data, ref uint dataBytes);

    [DllImport("msi.dll")]
    private static extern uint MsiViewClose(uint view);

    [DllImport("msi.dll")]
    private static extern uint MsiCloseHandle(uint handle);

    private static void Check(uint code, string operation)
    {
        if (code != ERROR_SUCCESS) throw new InvalidOperationException(operation + " failed with MSI error " + code + ".");
    }

    private static string GetString(uint record, uint field)
    {
        uint chars = 0;
        uint code = MsiRecordGetString(record, field, null, ref chars);
        if (code != ERROR_SUCCESS && code != 234) Check(code, "MsiRecordGetString(size)");
        var sb = new StringBuilder((int)chars + 1);
        chars += 1;
        Check(MsiRecordGetString(record, field, sb, ref chars), "MsiRecordGetString(data)");
        return sb.ToString();
    }

    public static string[] ExtractEmbeddedCabinets(string msiPath, string destinationDirectory)
    {
        Directory.CreateDirectory(destinationDirectory);
        uint database = 0;
        Check(MsiOpenDatabase(msiPath, IntPtr.Zero, out database), "MsiOpenDatabase");
        try
        {
            uint mediaView = 0;
            Check(MsiDatabaseOpenView(database, "SELECT `Cabinet` FROM `Media` WHERE `Cabinet` IS NOT NULL", out mediaView), "MsiDatabaseOpenView(Media)");
            try
            {
                Check(MsiViewExecute(mediaView, 0), "MsiViewExecute(Media)");
                var result = new System.Collections.Generic.List<string>();
                while (true)
                {
                    uint mediaRecord = 0;
                    uint fetch = MsiViewFetch(mediaView, out mediaRecord);
                    if (fetch == ERROR_NO_MORE_ITEMS) break;
                    Check(fetch, "MsiViewFetch(Media)");
                    try
                    {
                        string cabinet = GetString(mediaRecord, 1);
                        if (String.IsNullOrEmpty(cabinet) || cabinet[0] != '#') continue;
                        string streamName = cabinet.Substring(1);
                        string escaped = streamName.Replace("'", "''");
                        uint streamView = 0;
                        Check(MsiDatabaseOpenView(database, "SELECT `Name`,`Data` FROM `_Streams` WHERE `Name`='" + escaped + "'", out streamView), "MsiDatabaseOpenView(_Streams)");
                        try
                        {
                            Check(MsiViewExecute(streamView, 0), "MsiViewExecute(_Streams)");
                            uint streamRecord = 0;
                            uint sf = MsiViewFetch(streamView, out streamRecord);
                            if (sf == ERROR_NO_MORE_ITEMS) throw new InvalidOperationException("Embedded cabinet stream not found: " + streamName);
                            Check(sf, "MsiViewFetch(_Streams)");
                            try
                            {
                                string outPath = Path.Combine(destinationDirectory, streamName);
                                using (var output = new FileStream(outPath, FileMode.Create, FileAccess.Write, FileShare.None))
                                {
                                    byte[] buffer = new byte[65536];
                                    while (true)
                                    {
                                        uint count = (uint)buffer.Length;
                                        Check(MsiRecordReadStream(streamRecord, 2, buffer, ref count), "MsiRecordReadStream");
                                        if (count == 0) break;
                                        output.Write(buffer, 0, (int)count);
                                    }
                                }
                                result.Add(outPath);
                            }
                            finally { if (streamRecord != 0) MsiCloseHandle(streamRecord); }
                        }
                        finally { if (streamView != 0) { MsiViewClose(streamView); MsiCloseHandle(streamView); } }
                    }
                    finally { if (mediaRecord != 0) MsiCloseHandle(mediaRecord); }
                }
                if (result.Count == 0) throw new InvalidOperationException("MSI contains no embedded cabinet declared in the Media table.");
                return result.ToArray();
            }
            finally { if (mediaView != 0) { MsiViewClose(mediaView); MsiCloseHandle(mediaView); } }
        }
        finally { if (database != 0) MsiCloseHandle(database); }
    }
}
'@

if(-not ('RemoldMsiNative' -as [type])){
    Add-Type -TypeDefinition $native -Language CSharp
}

$temp=Join-Path ([IO.Path]::GetDirectoryName($OutputPath)) 'msi-native-extract'
if(Test-Path -LiteralPath $temp){Remove-Item -LiteralPath $temp -Recurse -Force}
New-Item -ItemType Directory -Force $temp|Out-Null
$cabDir=Join-Path $temp 'cab'
$outDir=Join-Path $temp 'files'
New-Item -ItemType Directory -Force $cabDir,$outDir|Out-Null

$cabinets=[RemoldMsiNative]::ExtractEmbeddedCabinets((Resolve-Path -LiteralPath $MsiPath).Path,$cabDir)
$expand=Join-Path $env:SystemRoot 'System32\expand.exe'
if(!(Test-Path -LiteralPath $expand -PathType Leaf)){throw "Windows expand.exe not found: $expand"}

foreach($cab in $cabinets){
    & $expand ("-F:{0}" -f $ExpectedName) $cab $outDir | Out-Host
    $exact=Join-Path $outDir $ExpectedName
    if(!(Test-Path -LiteralPath $exact -PathType Leaf)){
        & $expand '-F:UACFirmware.*' $cab $outDir | Out-Host
        if($LASTEXITCODE -ne 0 -and $LASTEXITCODE -ne 1){throw "expand.exe failed for embedded cabinet '$cab' (exit $LASTEXITCODE)."}
    }
}

$candidate=Get-ChildItem -LiteralPath $outDir -File -ErrorAction SilentlyContinue |
    Where-Object{$_.Name -eq $ExpectedName -or $_.Name -like 'UACFirmware.*' -or $_.Name -eq 'UACFirmware'} |
    Sort-Object @{Expression={if($_.Name -eq $ExpectedName){0}elseif($_.Name -eq 'UACFirmware'){1}else{2}}},FullName |
    Select-Object -First 1
if(!$candidate){
    throw ("UACFirmware was not found after native MSI/CAB extraction. Embedded cabinets: {0}" -f (($cabinets|ForEach-Object{[IO.Path]::GetFileName($_)}) -join ', '))
}
if($candidate.Length -lt 65536 -or $candidate.Length -gt 1048576){
    throw ("Extracted UACFirmware size is outside the conservative expected range: {0} bytes." -f $candidate.Length)
}
Copy-Item -LiteralPath $candidate.FullName -Destination $OutputPath -Force
Write-Host ("Native MSI/CAB extraction: PASS (cab={0}, file={1}, bytes={2})" -f ([IO.Path]::GetFileName($cabinets[0])),$candidate.Name,$candidate.Length) -ForegroundColor Green
