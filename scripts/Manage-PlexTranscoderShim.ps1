<#
.SYNOPSIS
    Installs, disables, repairs, or fully removes PlexTranscoderShim safely.

.DESCRIPTION
    Install and repair preserve every displaced executable in a timestamped
    backup directory with a SHA-256 manifest. Uninstall restores Plex's native
    transcoder and also retains a backup of the shim being removed.

    Status is read-only. Enable/Disable only update shim.ini and affect new
    transcodes. Install/Repair/Uninstall require Plex to be stopped; pass
    -StopPlex to let this script terminate the relevant processes.
#>
[CmdletBinding()]
param(
    [ValidateSet('Status','Install','Repair','Enable','Disable','Uninstall')]
    [string]$Action = 'Status',
    [string]$PlexDirectory = 'C:\Program Files\Plex\Plex Media Server',
    [string]$ShimBinary = (Join-Path (Split-Path $PSScriptRoot -Parent) 'dist\PlexTranscoderShim.exe'),
    [string]$ConfigTemplate = (Join-Path (Split-Path $PSScriptRoot -Parent) 'config\shim.ini.example'),
    [string]$BackupRoot = (Join-Path $env:ProgramData 'PlexTranscoderShim\Backups'),
    [switch]$StopPlex,
    [switch]$AllowUnverifiedNative,
    [Parameter(DontShow)][switch]$TestMode
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$active = Join-Path $PlexDirectory 'Plex Transcoder.exe'
$real = Join-Path $PlexDirectory 'Plex Transcoder Real.exe'
$config = Join-Path $PlexDirectory 'shim.ini'
$log = Join-Path $PlexDirectory 'shim.log'
$plexProcessNames = @('Plex Media Server','Plex Transcoder','Plex Transcoder Real','PlexScriptHost')

function Get-ExecutableKind {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return 'missing' }
    try {
        $name = [System.Reflection.AssemblyName]::GetAssemblyName($Path).Name
        if ($name -eq 'PlexTranscoderShim') { return 'shim' }
        return "managed:$name"
    }
    catch { return 'native' }
}

function Get-PlexSignatureInfo {
    param([Parameter(Mandatory)][string]$Path)
    if(-not (Test-Path -LiteralPath $Path -PathType Leaf)){
        return [pscustomobject]@{Status='Missing';Signer='';IsPlex=$false}
    }
    $signature=Get-AuthenticodeSignature -LiteralPath $Path
    $signer=if($signature.SignerCertificate){$signature.SignerCertificate.Subject}else{''}
    $isPlex=$signature.Status -eq 'Valid' -and $signer -match '(?i)(CN|O)\s*=\s*"?Plex(?:,\s*|\s+)Inc\.?"?'
    return [pscustomobject]@{Status=[string]$signature.Status;Signer=$signer;IsPlex=$isPlex}
}

function Assert-PlexNativeExecutable {
    param([Parameter(Mandatory)][string]$Path)
    if((Get-ExecutableKind -Path $Path) -ne 'native'){
        throw "Expected a native Plex executable: $Path"
    }
    $signature=Get-PlexSignatureInfo -Path $Path
    if($signature.IsPlex){return}
    $detail="Authenticode status=$($signature.Status), signer='$($signature.Signer)'"
    if($AllowUnverifiedNative){
        Write-Warning "Proceeding with an unverified native executable because -AllowUnverifiedNative was supplied: $Path ($detail)"
        return
    }
    throw "Refusing to use an unverified native executable: $Path ($detail). Repair/reinstall Plex, or inspect the file and explicitly pass -AllowUnverifiedNative."
}

function Get-FileDescription {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return [pscustomobject]@{ Path=$Path; Kind='missing'; Size=$null; Modified=$null; SHA256=$null }
    }
    $item = Get-Item -LiteralPath $Path
    $signature=if($item.Extension -eq '.exe'){Get-PlexSignatureInfo -Path $Path}else{$null}
    return [pscustomobject]@{
        Path=$Path
        Kind=Get-ExecutableKind -Path $Path
        Size=$item.Length
        Modified=$item.LastWriteTimeUtc.ToString('o')
        SHA256=(Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
        AuthenticodeStatus=if($signature){$signature.Status}else{$null}
        Signer=if($signature){$signature.Signer}else{$null}
    }
}

function Show-Status {
    Write-Host "`nPlexTranscoderShim status" -ForegroundColor Cyan
    Write-Host "Plex directory: $PlexDirectory"
    foreach ($path in @($active,$real,$config,$log)) {
        if (Test-Path -LiteralPath $path -PathType Leaf) {
            $item=Get-Item -LiteralPath $path
            $kind=if($item.Extension -eq '.exe'){Get-ExecutableKind -Path $path}else{'data'}
            if($kind -eq 'native'){
                $signature=Get-PlexSignatureInfo -Path $path
                $kind=if($signature.IsPlex){'plex-native'}else{"unverified/$($signature.Status)"}
            }
            Write-Host ('  {0,-28} {1,-18} {2,10:N0} bytes  {3:u}' -f $item.Name,$kind,$item.Length,$item.LastWriteTimeUtc)
        }
        else { Write-Host ('  {0,-28} missing' -f (Split-Path $path -Leaf)) -ForegroundColor DarkGray }
    }
    $running=if($TestMode){@()}else{@(Get-Process -Name $plexProcessNames -ErrorAction SilentlyContinue)}
    $processState=if($TestMode){'not checked (TestMode)'}elseif($running){($running.Name | Sort-Object -Unique) -join ', '}else{'stopped'}
    Write-Host "Plex processes: $processState"
    Write-Host ''
}

function Assert-Administrator {
    if($TestMode){
        $tempRoot=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')+'\'
        foreach($candidate in @($PlexDirectory,$BackupRoot)){
            $full=[IO.Path]::GetFullPath($candidate).TrimEnd('\')+'\'
            if(-not $full.StartsWith($tempRoot,[StringComparison]::OrdinalIgnoreCase) -or $full -eq $tempRoot){
                throw "TestMode only permits isolated subdirectories beneath $tempRoot"
            }
        }
        return
    }
    $identity=[Security.Principal.WindowsIdentity]::GetCurrent()
    $principal=[Security.Principal.WindowsPrincipal]::new($identity)
    if(-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)){
        throw 'This action modifies the Plex installation directory. Re-run PowerShell as Administrator.'
    }
}

function Stop-PlexForChange {
    if($TestMode){return}
    $running=@(Get-Process -Name $plexProcessNames -ErrorAction SilentlyContinue)
    if(-not $running){return}
    if(-not $StopPlex){
        throw "Plex is running. Stop it first, or repeat with -StopPlex. Running: $(($running.Name | Sort-Object -Unique) -join ', ')"
    }
    Write-Host "Stopping Plex processes: $(($running.Name | Sort-Object -Unique) -join ', ')" -ForegroundColor Yellow
    $running | Stop-Process -Force
    Start-Sleep -Seconds 2
    $remaining=@(Get-Process -Name $plexProcessNames -ErrorAction SilentlyContinue)
    if($remaining){throw "Could not stop: $(($remaining.Name | Sort-Object -Unique) -join ', ')"}
}

function New-StateBackup {
    param([Parameter(Mandatory)][string]$Reason)
    $directory=Join-Path $BackupRoot ((Get-Date).ToString('yyyyMMdd-HHmmss') + '-' + $Reason.ToLowerInvariant())
    [void](New-Item -ItemType Directory -Path $directory -Force)
    $records=[System.Collections.Generic.List[object]]::new()
    foreach($path in @($active,$real,$config,$log)){
        if(-not (Test-Path -LiteralPath $path -PathType Leaf)){continue}
        $record=Get-FileDescription -Path $path
        $records.Add($record)
        Copy-Item -LiteralPath $path -Destination (Join-Path $directory (Split-Path $path -Leaf)) -Force
    }
    $manifest=[pscustomobject]@{
        CreatedUtc=(Get-Date).ToUniversalTime().ToString('o')
        Reason=$Reason
        PlexDirectory=$PlexDirectory
        Files=$records
    }
    $manifest | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $directory 'manifest.json') -Encoding UTF8
    Write-Host "Backup: $directory" -ForegroundColor DarkGray
    return $directory
}

function Copy-FileSafely {
    param([Parameter(Mandatory)][string]$Source,[Parameter(Mandatory)][string]$Destination)
    $staged=$Destination + '.new.' + [guid]::NewGuid().ToString('N')
    try{
        Copy-Item -LiteralPath $Source -Destination $staged -Force
        $sourceHash=(Get-FileHash -LiteralPath $Source -Algorithm SHA256).Hash
        $stagedHash=(Get-FileHash -LiteralPath $staged -Algorithm SHA256).Hash
        if($sourceHash -ne $stagedHash){throw "Staged-file hash mismatch for $Destination"}
        Move-Item -LiteralPath $staged -Destination $Destination -Force
    }
    finally{Remove-Item -LiteralPath $staged -Force -ErrorAction SilentlyContinue}
}

function Assert-ShimBinary {
    if(-not (Test-Path -LiteralPath $ShimBinary -PathType Leaf)){
        throw "Shim binary not found: $ShimBinary. Run .\scripts\Build.ps1 first."
    }
    if((Get-ExecutableKind -Path $ShimBinary) -ne 'shim'){throw "Not a PlexTranscoderShim assembly: $ShimBinary"}
    if(-not (Test-Path -LiteralPath $config -PathType Leaf) -and
       -not (Test-Path -LiteralPath $ConfigTemplate -PathType Leaf)){
        throw "Configuration template not found: $ConfigTemplate"
    }
}

function Set-EnabledState {
    param([Parameter(Mandatory)][bool]$Enabled)
    if(-not (Test-Path -LiteralPath $config -PathType Leaf)){throw "Configuration not found: $config"}
    $value=if($Enabled){'1'}else{'0'}
    $text=Get-Content -LiteralPath $config -Raw
    if($text -match '(?m)^\s*enabled\s*='){
        $text=[regex]::Replace($text,'(?m)^\s*enabled\s*=.*$',"enabled = $value")
    }
    else{$text=$text.TrimEnd()+[Environment]::NewLine+"enabled = $value"+[Environment]::NewLine}
    $staged=$config+'.new.'+[guid]::NewGuid().ToString('N')
    try{
        Set-Content -LiteralPath $staged -Value $text -Encoding UTF8 -NoNewline
        Move-Item -LiteralPath $staged -Destination $config -Force
    }
    finally{Remove-Item -LiteralPath $staged -Force -ErrorAction SilentlyContinue}
    Write-Host "Shim enabled=$value. Existing transcodes are unchanged; new transcodes use this setting." -ForegroundColor Green
}

if(-not (Test-Path -LiteralPath $PlexDirectory -PathType Container)){throw "Plex directory not found: $PlexDirectory"}
if($Action -eq 'Status'){Show-Status; exit 0}

Assert-Administrator
if($Action -eq 'Enable'){Set-EnabledState -Enabled $true; exit 0}
if($Action -eq 'Disable'){Set-EnabledState -Enabled $false; exit 0}

if($Action -in @('Install','Repair')){Assert-ShimBinary}
$activeKind=Get-ExecutableKind -Path $active
$realKind=Get-ExecutableKind -Path $real

switch($Action){
    'Install' {
        if($activeKind -eq 'missing'){throw "Active Plex transcoder is missing: $active"}
        if($activeKind -eq 'shim' -and $realKind -ne 'native'){throw 'The active shim has no preserved native transcoder. Refusing to continue.'}
        if($activeKind -ne 'shim' -and $activeKind -ne 'native'){throw "Unexpected active executable type: $activeKind"}
        if($activeKind -eq 'native' -and $realKind -ne 'missing'){
            throw 'A preserved transcoder already exists. Use -Action Repair after a Plex update.'
        }
        if($activeKind -eq 'native'){Assert-PlexNativeExecutable -Path $active}
        if($activeKind -eq 'shim'){Assert-PlexNativeExecutable -Path $real}
        Stop-PlexForChange
        [void](New-StateBackup -Reason 'install')
        if($activeKind -eq 'native'){Copy-FileSafely -Source $active -Destination $real}
        Copy-FileSafely -Source $ShimBinary -Destination $active
        if(-not (Test-Path -LiteralPath $config)){Copy-Item -LiteralPath $ConfigTemplate -Destination $config}
        Write-Host 'Shim installed. Start Plex and run the health test after one HEVC QSV transcode.' -ForegroundColor Green
    }
    'Repair' {
        if($activeKind -ne 'native' -or $realKind -ne 'native'){
            throw "Repair expects Plex's current native transcoder at the active path and an older native copy at the preserved path. Found active=$activeKind, preserved=$realKind."
        }
        Assert-PlexNativeExecutable -Path $active
        Assert-PlexNativeExecutable -Path $real
        Stop-PlexForChange
        [void](New-StateBackup -Reason 'repair')
        Copy-FileSafely -Source $active -Destination $real
        Copy-FileSafely -Source $ShimBinary -Destination $active
        if(-not (Test-Path -LiteralPath $config)){Copy-Item -LiteralPath $ConfigTemplate -Destination $config}
        Write-Host 'Shim repaired around the current Plex transcoder. Start Plex and run the health test.' -ForegroundColor Green
    }
    'Uninstall' {
        if($activeKind -eq 'native' -and $realKind -eq 'missing'){
            Write-Host 'Already uninstalled; Plex Transcoder.exe is native and no preserved copy exists.' -ForegroundColor Yellow
            exit 0
        }
        if($activeKind -ne 'shim' -or $realKind -ne 'native'){
            throw "Safe uninstall requires active=shim and preserved=native. Found active=$activeKind, preserved=$realKind."
        }
        Assert-PlexNativeExecutable -Path $real
        Stop-PlexForChange
        [void](New-StateBackup -Reason 'uninstall')
        Copy-FileSafely -Source $real -Destination $active
        Remove-Item -LiteralPath $real -Force
        Write-Host 'Shim removed and Plex native transcoder restored. Configuration and logs were retained.' -ForegroundColor Green
    }
}

Show-Status
