[CmdletBinding()]
param(
    [string]$AssemblyPath = (Join-Path (Split-Path $PSScriptRoot -Parent) 'dist\PlexTranscoderShim.exe')
)

$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
Set-Variable -Name PSNativeCommandUseErrorActionPreference -Value $false -Scope Local

$root=Split-Path $PSScriptRoot -Parent
if(-not (Test-Path -LiteralPath $AssemblyPath -PathType Leaf)){& (Join-Path $root 'scripts\Build.ps1')}

$compilerCandidates=@(
    (Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'),
    (Join-Path $env:WINDIR 'Microsoft.NET\Framework\v4.0.30319\csc.exe')
)
$compiler=$compilerCandidates | Where-Object {Test-Path -LiteralPath $_ -PathType Leaf} | Select-Object -First 1
if(-not $compiler){throw '.NET Framework C# compiler (csc.exe) was not found.'}

$testRoot=Join-Path ([IO.Path]::GetTempPath()) ('PlexTranscoderShim.Tests.'+[guid]::NewGuid().ToString('N'))
$shim=Join-Path $testRoot 'Plex Transcoder.exe'
$real=Join-Path $testRoot 'Plex Transcoder Real.exe'
$config=Join-Path $testRoot 'shim.ini'
$log=Join-Path $testRoot 'shim.log'
$capture=Join-Path $testRoot 'child-command.txt'
$oldOutput=[Environment]::GetEnvironmentVariable('PLEX_SHIM_TEST_OUTPUT','Process')
$oldExit=[Environment]::GetEnvironmentVariable('PLEX_SHIM_TEST_EXIT_CODE','Process')
$oldSleep=[Environment]::GetEnvironmentVariable('PLEX_SHIM_TEST_SLEEP_MS','Process')
$jobShim=$null
$jobChildId=$null

function Write-TestConfig {
    param([Parameter(Mandatory)][string]$Text)
    Set-Content -LiteralPath $config -Value $Text -Encoding UTF8
}

function Invoke-TestShim {
    param([Parameter(Mandatory)][string[]]$ArgumentList,[int]$ExpectedExitCode=37)
    Remove-Item -LiteralPath $capture,($capture+'.pid') -Force -ErrorAction SilentlyContinue
    [Environment]::SetEnvironmentVariable('PLEX_SHIM_TEST_OUTPUT',$capture,'Process')
    [Environment]::SetEnvironmentVariable('PLEX_SHIM_TEST_EXIT_CODE',[string]$ExpectedExitCode,'Process')
    [Environment]::SetEnvironmentVariable('PLEX_SHIM_TEST_SLEEP_MS',$null,'Process')
    & $shim @ArgumentList
    $actualExitCode=$LASTEXITCODE
    if($actualExitCode -ne $ExpectedExitCode){throw "Expected shim exit code $ExpectedExitCode, got $actualExitCode."}
    if(-not (Test-Path -LiteralPath $capture -PathType Leaf)){throw 'The fake transcoder did not run.'}
    return Get-Content -LiteralPath $capture -Raw
}

try{
    [void](New-Item -ItemType Directory -Path $testRoot)
    Copy-Item -LiteralPath $AssemblyPath -Destination $shim
    & $compiler /nologo /target:exe /platform:x64 /optimize+ "/out:$real" (Join-Path $PSScriptRoot 'FakeTranscoder.cs')
    if($LASTEXITCODE -ne 0){throw "Fake transcoder compilation failed with exit code $LASTEXITCODE."}

    Write-TestConfig @"
enabled = 1
codecs = hevc_qsv
bitrate_factor = 0.90
bufsize_factor = 0
log = 1
log_max_mb = 5
logfile = $log
"@

    $rewritten=Invoke-TestShim -ArgumentList @('-codec:0','hevc_qsv','-q:0','20','-maxrate:0','10000k')
    if($rewritten -notmatch '-b:0 9000k' -or $rewritten -match '-q:0\s+20'){
        throw "The child did not receive rewritten arguments.`nActual: $rewritten"
    }

    Write-TestConfig @"
enabled = off
codecs = hevc_qsv
bitrate_factor = 0.90
log = 1
log_max_mb = 5
logfile = $log
"@
    $disabled=Invoke-TestShim -ArgumentList @('-codec:0','hevc_qsv','-q:0','20','-maxrate:0','10000k')
    if($disabled -notmatch '-q:0\s+20' -or $disabled -match '-b:0\s'){
        throw "Disabled mode did not pass arguments through unchanged.`nActual: $disabled"
    }

    Write-TestConfig @"
logfile = $log
enabled = ture
codecs = hevc_qsv
bitrate_factor = 0.90
log = 1
log_max_mb = 5
"@
    $invalid=Invoke-TestShim -ArgumentList @('-codec:0','hevc_qsv','-q:0','20','-maxrate:0','10000k')
    if($invalid -notmatch '-q:0\s+20' -or $invalid -match '-b:0\s'){
        throw 'Invalid configuration did not fail open to the original arguments.'
    }
    if((Get-Content -LiteralPath $log -Raw) -notmatch 'enabled must be one of'){
        throw 'Invalid configuration was not explained in the log.'
    }

    Write-TestConfig @"
enabled = 1
codecs = hevc_qsv
bitrate_factor = 0.90
log = 1
log_max_mb = 5
logfile = $log
"@
    Move-Item -LiteralPath $real -Destination ($real+'.held')
    try{
        [Environment]::SetEnvironmentVariable('PLEX_SHIM_TEST_OUTPUT',$capture,'Process')
        & $shim '-codec:0' 'hevc_qsv' '-q:0' '20' '-maxrate:0' '10000k' 2>$null
        if($LASTEXITCODE -ne 127){throw "Missing real transcoder should return 127, got $LASTEXITCODE."}
    }
    finally{Move-Item -LiteralPath ($real+'.held') -Destination $real}

    Remove-Item -LiteralPath $log -Force -ErrorAction SilentlyContinue
    [Environment]::SetEnvironmentVariable('PLEX_SHIM_TEST_OUTPUT',$null,'Process')
    [Environment]::SetEnvironmentVariable('PLEX_SHIM_TEST_EXIT_CODE','37','Process')
    $workers=@(1..12 | ForEach-Object {
        Start-Process -FilePath $shim -ArgumentList @('-codec:0','hevc_qsv','-q:0','20','-maxrate:0','10000k') -PassThru
    })
    foreach($worker in $workers){$worker.WaitForExit();if($worker.ExitCode -ne 37){throw "Concurrent shim exited $($worker.ExitCode)."}}
    $logLines=Get-Content -LiteralPath $log
    $inCount=@($logLines | Where-Object {$_ -match '\]\s+IN\s*:'}).Count
    $outCount=@($logLines | Where-Object {$_ -match '\]\s+OUT\s*:'}).Count
    if($inCount -ne 12 -or $outCount -ne 12){throw "Concurrent logging lost entries: IN=$inCount, OUT=$outCount."}

    Remove-Item -LiteralPath $capture,($capture+'.pid') -Force -ErrorAction SilentlyContinue
    [Environment]::SetEnvironmentVariable('PLEX_SHIM_TEST_OUTPUT',$capture,'Process')
    [Environment]::SetEnvironmentVariable('PLEX_SHIM_TEST_EXIT_CODE','0','Process')
    [Environment]::SetEnvironmentVariable('PLEX_SHIM_TEST_SLEEP_MS','30000','Process')
    $jobShim=Start-Process -FilePath $shim -ArgumentList @('-codec:0','h264_qsv') -PassThru
    $deadline=(Get-Date).AddSeconds(8)
    while(-not (Test-Path -LiteralPath ($capture+'.pid')) -and (Get-Date) -lt $deadline){Start-Sleep -Milliseconds 100}
    if(-not (Test-Path -LiteralPath ($capture+'.pid'))){throw 'Timed out waiting for the fake transcoder PID.'}
    $jobChildId=[int](Get-Content -LiteralPath ($capture+'.pid') -Raw)
    Stop-Process -Id $jobShim.Id -Force
    $jobShim.WaitForExit()
    $deadline=(Get-Date).AddSeconds(5)
    while((Get-Process -Id $jobChildId -ErrorAction SilentlyContinue) -and (Get-Date) -lt $deadline){Start-Sleep -Milliseconds 100}
    if(Get-Process -Id $jobChildId -ErrorAction SilentlyContinue){throw 'The real transcoder survived after the shim was terminated.'}
    $jobChildId=$null

    Write-Host 'All end-to-end tests passed.' -ForegroundColor Green
}
finally{
    if($jobShim -and -not $jobShim.HasExited){Stop-Process -Id $jobShim.Id -Force -ErrorAction SilentlyContinue}
    if($jobChildId){Stop-Process -Id $jobChildId -Force -ErrorAction SilentlyContinue}
    [Environment]::SetEnvironmentVariable('PLEX_SHIM_TEST_OUTPUT',$oldOutput,'Process')
    [Environment]::SetEnvironmentVariable('PLEX_SHIM_TEST_EXIT_CODE',$oldExit,'Process')
    [Environment]::SetEnvironmentVariable('PLEX_SHIM_TEST_SLEEP_MS',$oldSleep,'Process')
    if(Test-Path -LiteralPath $testRoot){Remove-Item -LiteralPath $testRoot -Recurse -Force}
}
