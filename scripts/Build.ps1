<#
.SYNOPSIS
    Builds PlexTranscoderShim with the C# compiler included with Windows.
#>
[CmdletBinding()]
param(
    [string]$OutputDirectory = (Join-Path (Split-Path $PSScriptRoot -Parent) 'dist')
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

if ($env:OS -ne 'Windows_NT') { throw 'PlexTranscoderShim can only be built for Windows.' }

$root = Split-Path $PSScriptRoot -Parent
$source = Join-Path $root 'src\PlexTranscoderShim.cs'
$config = Join-Path $root 'config\shim.ini.example'
$compilerCandidates = @(
    (Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'),
    (Join-Path $env:WINDIR 'Microsoft.NET\Framework\v4.0.30319\csc.exe')
)
$compiler = $compilerCandidates | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } | Select-Object -First 1
if (-not $compiler) { throw '.NET Framework C# compiler (csc.exe) was not found.' }
if (-not (Test-Path -LiteralPath $source -PathType Leaf)) { throw "Source file not found: $source" }

[void](New-Item -ItemType Directory -Path $OutputDirectory -Force)
$output = Join-Path $OutputDirectory 'PlexTranscoderShim.exe'

& $compiler /nologo /target:exe /platform:x64 /optimize+ /warnaserror+ "/out:$output" $source
if ($LASTEXITCODE -ne 0) { throw "C# compilation failed with exit code $LASTEXITCODE." }

$assemblyName = [System.Reflection.AssemblyName]::GetAssemblyName($output)
if ($assemblyName.Name -ne 'PlexTranscoderShim') {
    throw "Unexpected assembly identity: $($assemblyName.Name)"
}

Copy-Item -LiteralPath $config -Destination (Join-Path $OutputDirectory 'shim.ini') -Force
$hash = Get-FileHash -LiteralPath $output -Algorithm SHA256
Write-Host "Built $output" -ForegroundColor Green
Write-Host "SHA-256 $($hash.Hash)" -ForegroundColor DarkGray
