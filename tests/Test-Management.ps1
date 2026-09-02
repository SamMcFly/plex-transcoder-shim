[CmdletBinding()]
param(
    [string]$AssemblyPath = (Join-Path (Split-Path $PSScriptRoot -Parent) 'dist\PlexTranscoderShim.exe')
)

$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
Set-Variable -Name PSNativeCommandUseErrorActionPreference -Value $false -Scope Local

$root=Split-Path $PSScriptRoot -Parent
if(-not (Test-Path -LiteralPath $AssemblyPath -PathType Leaf)){& (Join-Path $root 'scripts\Build.ps1')}

$testRoot=Join-Path ([IO.Path]::GetTempPath()) ('PlexTranscoderShim.Management.Tests.'+[guid]::NewGuid().ToString('N'))
$plexDir=Join-Path $testRoot 'Plex Media Server'
$backupRoot=Join-Path $testRoot 'Backups'
$manager=Join-Path $root 'scripts\Manage-PlexTranscoderShim.ps1'
$template=Join-Path $root 'config\shim.ini.example'
$active=Join-Path $plexDir 'Plex Transcoder.exe'
$real=Join-Path $plexDir 'Plex Transcoder Real.exe'
$config=Join-Path $plexDir 'shim.ini'
$nativeBefore=Join-Path $env:WINDIR 'System32\where.exe'
$nativeAfter=Join-Path $env:WINDIR 'System32\whoami.exe'
$shell=(Get-Process -Id $PID).Path

function Invoke-Manager {
    param([Parameter(Mandatory)][string]$Action)
    & $shell -NoProfile -ExecutionPolicy Bypass -File $manager `
        -Action $Action `
        -PlexDirectory $plexDir `
        -ShimBinary $AssemblyPath `
        -ConfigTemplate $template `
        -BackupRoot $backupRoot `
        -AllowUnverifiedNative `
        -TestMode
    if($LASTEXITCODE -ne 0){throw "Management action $Action failed with exit code $LASTEXITCODE."}
}

try{
    [void](New-Item -ItemType Directory -Path $plexDir)
    Copy-Item -LiteralPath $nativeBefore -Destination $active
    $beforeHash=(Get-FileHash -LiteralPath $active -Algorithm SHA256).Hash

    Invoke-Manager Install
    if([Reflection.AssemblyName]::GetAssemblyName($active).Name -ne 'PlexTranscoderShim'){throw 'Install did not activate the shim.'}
    if((Get-FileHash -LiteralPath $real -Algorithm SHA256).Hash -ne $beforeHash){throw 'Install did not preserve the original native executable.'}
    if(-not (Test-Path -LiteralPath $config -PathType Leaf)){throw 'Install did not create shim.ini.'}

    Invoke-Manager Disable
    if((Get-Content -LiteralPath $config -Raw) -notmatch '(?m)^enabled\s*=\s*0\s*$'){throw 'Disable did not update shim.ini.'}
    Invoke-Manager Enable
    if((Get-Content -LiteralPath $config -Raw) -notmatch '(?m)^enabled\s*=\s*1\s*$'){throw 'Enable did not update shim.ini.'}

    Copy-Item -LiteralPath $nativeAfter -Destination $active -Force
    $afterHash=(Get-FileHash -LiteralPath $active -Algorithm SHA256).Hash
    Invoke-Manager Repair
    if([Reflection.AssemblyName]::GetAssemblyName($active).Name -ne 'PlexTranscoderShim'){throw 'Repair did not reactivate the shim.'}
    if((Get-FileHash -LiteralPath $real -Algorithm SHA256).Hash -ne $afterHash){throw 'Repair retained a stale native executable.'}

    Invoke-Manager Uninstall
    try{[void][Reflection.AssemblyName]::GetAssemblyName($active);throw 'Uninstall left a managed shim at the active path.'}catch [BadImageFormatException]{}
    if((Get-FileHash -LiteralPath $active -Algorithm SHA256).Hash -ne $afterHash){throw 'Uninstall did not restore the current native executable.'}
    if(Test-Path -LiteralPath $real){throw 'Uninstall left a redundant preserved executable.'}

    $manifests=@(Get-ChildItem -LiteralPath $backupRoot -Filter manifest.json -File -Recurse)
    if($manifests.Count -ne 3){throw "Expected three state manifests, found $($manifests.Count)."}
    foreach($manifest in $manifests){[void](Get-Content -LiteralPath $manifest.FullName -Raw | ConvertFrom-Json)}

    Write-Host 'All management lifecycle tests passed.' -ForegroundColor Green
}
finally{
    if(Test-Path -LiteralPath $testRoot){Remove-Item -LiteralPath $testRoot -Recurse -Force}
}
