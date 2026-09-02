[CmdletBinding()]
param(
    [string]$AssemblyPath = (Join-Path (Split-Path $PSScriptRoot -Parent) 'dist\PlexTranscoderShim.exe')
)

$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest

if(-not (Test-Path -LiteralPath $AssemblyPath -PathType Leaf)){
    & (Join-Path (Split-Path $PSScriptRoot -Parent) 'scripts\Build.ps1')
}

$assembly=[Reflection.Assembly]::LoadFile((Resolve-Path -LiteralPath $AssemblyPath).Path)
$type=$assembly.GetType('Shim',$true)
$flags=[Reflection.BindingFlags]'NonPublic,Static'
$rewrite=$type.GetMethod('Rewrite',$flags)
$redact=$type.GetMethod('RedactSensitiveLogText',$flags)
$validate=$type.GetMethod('ValidateConfig',$flags)
$parseBoolean=$type.GetMethod('ParseBoolean',$flags)
$getDefaultLog=$type.GetMethod('GetDefaultLogFile',$flags)

function Set-PrivateField([string]$Name,$Value){$type.GetField($Name,$flags).SetValue($null,$Value)}
function Reset-Config {
    $codecs=[System.Collections.Generic.List[string]]::new()
    $codecs.Add([regex]::Escape('hevc_qsv'))
    Set-PrivateField '_codecs' $codecs
    Set-PrivateField '_bitrateFactor' ([double]0.90)
    Set-PrivateField '_bufsizeFactor' ([double]0.0)
    Set-PrivateField '_extraArgs' ''
    Set-PrivateField '_logMaxBytes' ([long](5MB))
    Set-PrivateField '_logFile' (Join-Path ([IO.Path]::GetTempPath()) 'PlexTranscoderShim.Tests\shim.log')
}
function Invoke-Rewrite([string]$Arguments){return [string]$rewrite.Invoke($null,@($Arguments))}
function Assert-Match([string]$Value,[string]$Pattern,[string]$Message){if($Value -notmatch $Pattern){throw "$Message`nActual: $Value"}}
function Assert-NoMatch([string]$Value,[string]$Pattern,[string]$Message){if($Value -match $Pattern){throw "$Message`nActual: $Value"}}
function Test-InnerExceptionType($Exception,[type]$Expected){
    for($cursor=$Exception;$cursor;$cursor=$cursor.InnerException){if($Expected.IsInstanceOfType($cursor)){return $true}}
    return $false
}

if(-not [IO.Path]::IsPathRooted([string]$getDefaultLog.Invoke($null,@()))){throw 'Default log path is not absolute.'}
if(-not [bool]$parseBoolean.Invoke($null,@('enabled','yes'))){throw 'A documented true value was rejected.'}
if([bool]$parseBoolean.Invoke($null,@('enabled','off'))){throw 'A documented false value was accepted as true.'}
$invalidBooleanCaught=$false
try{[void]$parseBoolean.Invoke($null,@('enabled','ture'))}catch{$invalidBooleanCaught=Test-InnerExceptionType $_.Exception ([IO.InvalidDataException])}
if(-not $invalidBooleanCaught){throw 'An invalid Boolean value did not raise a configuration error.'}

Reset-Config
$basic=Invoke-Rewrite '-codec:0 hevc -i "movie.mkv" -codec:0 hevc_qsv -q:0 20 -maxrate:0 10000k -bufsize:0 20000k'
Assert-Match $basic '-codec:0 hevc_qsv -b:0 9000k -maxrate:0 10000k' 'Quality mode was not replaced with constrained VBR.'
Assert-NoMatch $basic '-q:0\s' 'The output quality option survived.'

$other=Invoke-Rewrite '-codec:0 h264_qsv -q:0 20 -maxrate:0 10000k'
if($other -ne '-codec:0 h264_qsv -q:0 20 -maxrate:0 10000k'){throw 'An unconfigured encoder was modified.'}

$noAnchor=Invoke-Rewrite '-codec:0 hevc_qsv -q:0 20'
if($noAnchor -ne '-codec:0 hevc_qsv -q:0 20'){throw 'Arguments without maxrate must pass through unchanged.'}

$both=Invoke-Rewrite '-codec:0 hevc_qsv -q:0 20 -b:0 1234k -maxrate:0 10000k'
Assert-NoMatch $both '-q:0\s' 'Conflicting quality mode survived.'
if(([regex]::Matches($both,'-b:0\s')).Count -ne 1){throw 'Conflicting input produced duplicate bitrate options.'}
Assert-Match $both '-b:0 9000k' 'Existing bitrate was not normalized.'

Set-PrivateField '_bufsizeFactor' ([double]1.5)
$buffer=Invoke-Rewrite '-codec:2 hevc_qsv -q:2 18 -maxrate:2 8m -bufsize:2 16m'
Assert-Match $buffer '-b:2 7200k' 'Megabit maxrate conversion failed.'
Assert-Match $buffer '-bufsize:2 12000k' 'Buffer-size factor was not applied.'

Set-PrivateField '_extraArgs' '-adaptive_i:{i} 1 -metadata comment=$literal'
$extra=Invoke-Rewrite '-codec:1 hevc_qsv -q:1 20 -maxrate:1 10000k'
Assert-Match $extra '-maxrate:1 10000k -adaptive_i:1 1 -metadata comment=\$literal' 'Extra arguments were not inserted literally.'

$sanitized=[string]$redact.Invoke($null,@('url?X-Plex-Token=secret123&x=1 api_key%3Dabcdef%26x'))
Assert-NoMatch $sanitized 'secret123|abcdef' 'Sensitive query values were not redacted.'
Assert-Match $sanitized '<redacted>' 'Redaction marker is missing.'

Reset-Config
Set-PrivateField '_bitrateFactor' ([double]1.1)
$invalidCaught=$false
try{[void]$validate.Invoke($null,@())}catch{$invalidCaught=Test-InnerExceptionType $_.Exception ([IO.InvalidDataException])}
if(-not $invalidCaught){throw 'Unsafe bitrate_factor was not rejected.'}

Reset-Config
Set-PrivateField '_logFile' 'relative\shim.log'
$invalidLogCaught=$false
try{[void]$validate.Invoke($null,@())}catch{$invalidLogCaught=Test-InnerExceptionType $_.Exception ([IO.InvalidDataException])}
if(-not $invalidLogCaught){throw 'A relative logfile path was not rejected.'}

Write-Host 'All rewrite tests passed.' -ForegroundColor Green
