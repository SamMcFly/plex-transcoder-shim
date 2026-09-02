<#
.SYNOPSIS
    Verifies that the Plex Transcoder shim is installed, enabled, and actually
    rewriting rate control.

.DESCRIPTION
    Read-only. The shim replaces "Plex Transcoder.exe" and forwards to the
    renamed original, rewriting hevc_qsv's `-q:N` into `-b:N` so QSV is given
    an explicit target bitrate derived from the session's maxrate.

    WHY A CHECKER IS NEEDED AT ALL
    Plex's own log is useless for verifying this. The "Job running:" line always
    shows `-q:0 20` because Plex logs its intent BEFORE launching the process
    and cannot see the rewrite. Anyone verifying from that line concludes the
    shim never ran.

    THE FAILURE MODE THIS CATCHES
    A Plex update overwrites "Plex Transcoder.exe" with the real binary. The
    shim silently disappears, every transcode reverts to `-q:0`, and remote 4K
    sessions start overshooting their cap and stalling again - with nothing in
    any log saying so.

    HOW THAT IS DETECTED - AND WHY NOT BY FILE SIZE OR HASH DIFFERENCE
    Plex Transcoder is a thin native binary, so size alone is not an identity
    check. A Plex update can also leave DIFFERENT Plex-signed versions in the
    active and renamed paths, making their hashes different even though both
    files are stock Plex executables. The checker therefore requires the active
    executable's managed assembly name to be PlexTranscoderShim; hash comparison
    is retained only as a secondary consistency check.

    Exits non-zero if anything is wrong, so it can be scheduled.

.EXAMPLE
    .\scripts\Test-PlexTranscoderShim.ps1
    .\scripts\Test-PlexTranscoderShim.ps1 -Quiet
    .\scripts\Test-PlexTranscoderShim.ps1 -Hours 168
#>

[CmdletBinding()]
param(
    [string] $PlexDir = 'C:\Program Files\Plex\Plex Media Server',
    [string] $ShimLog = '',      # blank = take it from shim.ini, then search
    [string] $ShimIni = '',      # blank = find shim.ini under $PlexDir
    [int]    $Hours   = 48,
    [switch] $Quiet
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$script:Results = [System.Collections.Generic.List[object]]::new()

function Add-Result {
    param(
        [string]$Check,
        [ValidateSet('PASS','WARN','FAIL','INFO')][string]$Status,
        [string]$Detail
    )
    $script:Results.Add([pscustomobject]@{ Check = $Check; Status = $Status; Detail = $Detail })
    if ($Quiet -and $Status -in @('PASS','INFO')) { return }
    $colour = switch ($Status) { 'PASS' {'Green'} 'WARN' {'Yellow'} 'FAIL' {'Red'} default {'DarkGray'} }
    Write-Host ("  {0}  {1,-26} {2}" -f $Status.PadRight(4), $Check, $Detail) -ForegroundColor $colour
}

Write-Host "`nPlex Transcoder shim check  -  $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" -ForegroundColor Cyan
Write-Host ('=' * 72) -ForegroundColor DarkGray

if (-not (Test-Path -LiteralPath $PlexDir)) { throw "Plex directory not found: $PlexDir" }

# ---------------------------------------------------------------------------
# 1. Installation
# ---------------------------------------------------------------------------
Write-Host "`nInstallation" -ForegroundColor Cyan

$active = Join-Path $PlexDir 'Plex Transcoder.exe'
$real   = Join-Path $PlexDir 'Plex Transcoder Real.exe'

if (-not (Test-Path -LiteralPath $active)) {
    Add-Result 'Transcoder present' 'FAIL' "missing: $active"
    Write-Host ''
    exit 2
}
$activeItem = Get-Item -LiteralPath $active

if (-not (Test-Path -LiteralPath $real)) {
    Add-Result 'Shim installed' 'FAIL' "'Plex Transcoder Real.exe' is missing - the shim is NOT installed"
    Write-Host "`nRun .\scripts\Build.ps1, then use Manage-PlexTranscoderShim.ps1 to install or repair.`n" -ForegroundColor Yellow
    exit 1
}
$realItem = Get-Item -LiteralPath $real
Add-Result 'Original preserved' 'PASS' `
    ("Plex Transcoder Real.exe - {0:N0} KB" -f ($realItem.Length / 1KB))

# Hash comparison, not size. The real transcoder is a thin ~0.3 MB binary that
# loads codecs from the external bundle, so size alone cannot tell them apart.
$activeHash = (Get-FileHash -LiteralPath $active -Algorithm SHA256).Hash
$realHash   = (Get-FileHash -LiteralPath $real   -Algorithm SHA256).Hash

$activeAssemblyName = ''
try {
    $activeAssemblyName = [System.Reflection.AssemblyName]::GetAssemblyName($active).Name
}
catch {
    # Plex's stock transcoder is native code, not a managed .NET assembly.
    $activeAssemblyName = ''
}

if ($activeAssemblyName -ne 'PlexTranscoderShim') {
    Add-Result 'Active transcoder is shim' 'FAIL' `
        'Plex Transcoder.exe is not the PlexTranscoderShim assembly - it was likely overwritten by a Plex update'
}
elseif ($activeHash -eq $realHash) {
    Add-Result 'Active transcoder is shim' 'FAIL' `
        'Plex Transcoder.exe is byte-identical to the renamed original - the shim has been OVERWRITTEN (Plex update?)'
}
else {
    Add-Result 'Active transcoder is shim' 'PASS' `
        ("PlexTranscoderShim assembly - {0:N0} KB" -f ($activeItem.Length / 1KB))
}

# The renamed original does NOT get refreshed by a Plex update, and the Codecs
# bundle is version-matched to it - a stale original breaks decoding.
$pms = Join-Path $PlexDir 'Plex Media Server.exe'
if (Test-Path -LiteralPath $pms) {
    $pmsItem = Get-Item -LiteralPath $pms
    if ($pmsItem.LastWriteTime -gt $realItem.LastWriteTime.AddMinutes(5)) {
        $days = [math]::Round(($pmsItem.LastWriteTime - $realItem.LastWriteTime).TotalDays, 1)
        Add-Result 'Original is current' 'WARN' `
            "Plex Media Server.exe is $days days newer than the renamed transcoder - revert and reinstall the shim"
    }
    else { Add-Result 'Original is current' 'PASS' 'no Plex update since the shim was installed' }
}

# ---------------------------------------------------------------------------
# 2. Configuration - the ini also tells us where the log lives
# ---------------------------------------------------------------------------
Write-Host "`nConfiguration" -ForegroundColor Cyan

if (-not $ShimIni) {
    $iniFile = Get-ChildItem -LiteralPath $PlexDir -Filter 'shim.ini' -File -ErrorAction SilentlyContinue |
               Select-Object -First 1
    if ($iniFile) { $ShimIni = $iniFile.FullName }
}

$cfg = @{}
if ($ShimIni -and (Test-Path -LiteralPath $ShimIni)) {
    foreach ($l in (Get-Content -LiteralPath $ShimIni)) {
        if ($l -match '^\s*(?<k>[A-Za-z_]+)\s*=\s*(?<v>.*?)\s*$') { $cfg[$Matches['k'].ToLower()] = $Matches['v'] }
    }
    Add-Result 'shim.ini found' 'PASS' $ShimIni
}
else {
    Add-Result 'shim.ini found' 'WARN' "not found under $PlexDir - shim will use built-in defaults"
}

# An installed shim with enabled=0 passes everything through untouched, which
# looks healthy from every other angle.
if ($cfg.ContainsKey('enabled')) {
    if ($cfg['enabled'] -eq '0') {
        Add-Result 'Shim enabled' 'FAIL' 'enabled = 0 - the shim is installed but passing through unmodified'
    }
    else { Add-Result 'Shim enabled' 'PASS' "enabled = $($cfg['enabled'])" }
}

foreach ($k in 'codecs','bitrate_factor','bufsize_factor','priority','extra') {
    if ($cfg.ContainsKey($k)) {
        $v = if ($cfg[$k] -eq '') { '(empty)' } else { $cfg[$k] }
        Add-Result $k 'INFO' $v
    }
}

# ---------------------------------------------------------------------------
# 3. shim.log - is it actually rewriting?
# ---------------------------------------------------------------------------
Write-Host "`nActivity (last $Hours h)" -ForegroundColor Cyan

if ($cfg.ContainsKey('log') -and $cfg['log'] -eq '0') {
    Add-Result 'Logging' 'WARN' 'log = 0 in shim.ini - activity cannot be verified'
    Write-Host ''
}
else {
    # Prefer the path the ini declares; only guess if it does not say.
    if (-not $ShimLog -and $cfg.ContainsKey('logfile')) { $ShimLog = $cfg['logfile'] }
    if (-not $ShimLog) {
        foreach ($dir in @($PlexDir, $env:TEMP)) {
            if (-not $dir -or -not (Test-Path -LiteralPath $dir)) { continue }
            $f = Get-ChildItem -LiteralPath $dir -Filter '*shim*.log' -File -ErrorAction SilentlyContinue |
                 Sort-Object LastWriteTime -Descending | Select-Object -First 1
            if ($f) { $ShimLog = $f.FullName; break }
        }
    }

    if (-not $ShimLog -or -not (Test-Path -LiteralPath $ShimLog)) {
        Add-Result 'shim.log' 'FAIL' `
            ("no log at '{0}' - the shim is not logging, or not running" -f $(if ($ShimLog) { $ShimLog } else { 'any known location' }))
    }
    else {
        $logItem = Get-Item -LiteralPath $ShimLog
        $ageH = [math]::Round(((Get-Date) - $logItem.LastWriteTime).TotalHours, 1)
        Add-Result 'shim.log found' 'PASS' `
            ("{0} - {1:N0} KB, last written {2} h ago" -f $logItem.Name, ($logItem.Length / 1KB), $ageH)

        if ($cfg.ContainsKey('log_max_mb') -and $logItem.Length -ge ([double]$cfg['log_max_mb'] * 1MB * 0.9)) {
            Add-Result 'Log window' 'INFO' `
                "near the $($cfg['log_max_mb']) MB cap - older history has rolled off, so counts below may be short"
        }

        $cut = (Get-Date).AddHours(-$Hours)
        $rxStamp = [regex]'(?<ts>\d{4}-\d{2}-\d{2}[ T]\d{2}:\d{2}:\d{2})'

        $inCount = 0; $outCount = 0; $qSurvived = 0; $noAnchor = 0
        $ratios   = [System.Collections.Generic.List[double]]::new()
        $maxrates = @{}
        $lastActivity = $null
        $parsedAny = $false

        foreach ($line in (Get-Content -LiteralPath $ShimLog -ErrorAction SilentlyContinue)) {
            if ([string]::IsNullOrWhiteSpace($line)) { continue }

            $when = $null
            $ms = $rxStamp.Match($line)
            if ($ms.Success) {
                $tmp = [datetime]::MinValue
                if ([datetime]::TryParse($ms.Groups['ts'].Value, [ref]$tmp)) { $when = $tmp }
            }
            if ($when -and $when -lt $cut) { continue }

            if ($line -match '\bIN\b') {
                $parsedAny = $true; $inCount++
                if ($when) { $lastActivity = $when }
                if ($line -notmatch '-maxrate:\d+\s+\d+') { $noAnchor++ }
            }
            elseif ($line -match '\bOUT\b') {
                $parsedAny = $true; $outCount++
                if ($when) { $lastActivity = $when }
                if ($line -match '-q:\d+\s') { $qSurvived++ }

                $b = 0.0; $mr = 0.0
                if ($line -match '-b:\d+\s+(\d+)k')       { $b  = [double]$Matches[1] }
                if ($line -match '-maxrate:\d+\s+(\d+)k') { $mr = [double]$Matches[1]; $maxrates["$mr"] = 1 }
                if ($b -gt 0 -and $mr -gt 0) { $ratios.Add([math]::Round($b / $mr, 3)) }
            }
        }

        if (-not $parsedAny) {
            Add-Result 'shim.log parsed' 'WARN' 'no IN/OUT lines recognised in the window - tail follows'
            Get-Content -LiteralPath $ShimLog -Tail 5 | ForEach-Object { Write-Host "      $_" -ForegroundColor DarkGray }
        }
        else {
            Add-Result 'Invocations' 'INFO' "$inCount IN, $outCount OUT"

            if ($outCount -eq 0 -and $inCount -gt 0) {
                Add-Result 'Rewrites happening' 'FAIL' "$inCount invocations but ZERO rewrites"
            }
            elseif ($outCount -eq 0) {
                Add-Result 'Rewrites happening' 'WARN' "no activity in the last $Hours h - has anything transcoded?"
            }
            else { Add-Result 'Rewrites happening' 'PASS' "$outCount rewrites" }

            if ($qSurvived -gt 0) {
                Add-Result 'Rate control replaced' 'FAIL' "$qSurvived OUT line(s) still carry -q: - quality mode survived"
            }
            elseif ($outCount -gt 0) {
                Add-Result 'Rate control replaced' 'PASS' 'no -q: survives into any OUT line'
            }

            $unexplained = $inCount - $outCount - $noAnchor
            if ($unexplained -gt 0) {
                Add-Result 'IN/OUT pairing' 'WARN' `
                    "$unexplained invocation(s) had a -maxrate but produced no OUT - shim may be failing open"
            }
            elseif ($inCount -gt 0) {
                Add-Result 'IN/OUT pairing' 'PASS' `
                    ('all accounted for' + $(if ($noAnchor -gt 0) { " ($noAnchor correctly skipped: no -maxrate)" } else { '' }))
            }

            if ($ratios.Count -gt 0) {
                $distinct = @($ratios | Sort-Object -Unique)
                $spread = if ($distinct.Count -eq 1) { "constant $($distinct[0])" }
                          else { "$($distinct.Count) values: $(($distinct | Select-Object -First 6) -join ', ')" }
                $expected = if ($cfg.ContainsKey('bitrate_factor')) { [double]$cfg['bitrate_factor'] } else { 0 }
                if ($expected -gt 0 -and $distinct.Count -eq 1 -and [math]::Abs($distinct[0] - $expected) -gt 0.02) {
                    Add-Result 'bitrate_factor observed' 'WARN' "$spread but shim.ini says $expected"
                }
                else { Add-Result 'bitrate_factor observed' 'PASS' $spread }

                Add-Result 'Session maxrates seen' 'INFO' `
                    ("$($maxrates.Keys.Count) distinct: " + (($maxrates.Keys | Sort-Object { [int]$_ } | Select-Object -First 8) -join 'k, ') + 'k')
            }

            if ($lastActivity) {
                $h = [math]::Round(((Get-Date) - $lastActivity).TotalHours, 1)
                Add-Result 'Last invocation' $(if ($h -le 24) {'PASS'} else {'INFO'}) "$lastActivity ($h h ago)"
            }
        }
    }
}

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
$fail = @($script:Results | Where-Object Status -eq 'FAIL')
$warn = @($script:Results | Where-Object Status -eq 'WARN')
$pass = @($script:Results | Where-Object Status -eq 'PASS')

Write-Host "`n$('=' * 72)" -ForegroundColor DarkGray
if ($fail.Count) {
    Write-Host "FAILED  -  $($fail.Count) failed, $($warn.Count) warnings, $($pass.Count) passed" -ForegroundColor Red
    $fail | ForEach-Object { Write-Host "  * $($_.Check): $($_.Detail)" -ForegroundColor Red }
    Write-Host "`n  Review the failed checks before relying on rewritten rate control." -ForegroundColor Red
    Write-Host '  If a Plex update replaced the shim, use Manage-PlexTranscoderShim.ps1 -Action Status' -ForegroundColor Yellow
    Write-Host "  and follow the documented Install/Repair path; do not restore a stale native executable.`n" -ForegroundColor Yellow
}
elseif ($warn.Count) {
    Write-Host "OK with warnings  -  $($warn.Count) warnings, $($pass.Count) passed`n" -ForegroundColor Yellow
}
else {
    Write-Host "Shim healthy - all $($pass.Count) checks passed`n" -ForegroundColor Green
}

exit $(if ($fail.Count) { 1 } else { 0 })
