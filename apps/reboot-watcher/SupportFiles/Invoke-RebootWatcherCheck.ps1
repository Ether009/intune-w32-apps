<#
.SYNOPSIS
Reboot Watcher - uptime check and forced-reboot enforcement (runs as SYSTEM).

.DESCRIPTION
Reads the device's uptime and, based on the thresholds in RebootWatcherConfig.json,
writes state to HKLM:\SOFTWARE\LundsFontanhus\RebootWatcher for the interactive-user
notification task to read, and - once uptime reaches the force-reboot threshold -
issues the actual restart itself via shutdown.exe. Runs as SYSTEM so the forced
restart works even if no one is logged on, and so the shutdown.exe countdown notice
(which is rendered at the system level, not tied to the calling session) reaches
whichever user is signed in.

.PARAMETER ConfigPath
Path to RebootWatcherConfig.json.
#>

[CmdletBinding()]
param
(
    [Parameter(Mandatory = $true)]
    [System.String]$ConfigPath
)

$ErrorActionPreference = 'Stop'

$RebootWatcherRegKey = 'HKLM:\SOFTWARE\LundsFontanhus\RebootWatcher'
$LogPath = Join-Path $env:ProgramData 'LundsFontanhus\RebootWatcher\Logs\Invoke-RebootWatcherCheck.log'

function Write-Log
{
    param ([Parameter(Mandatory = $true)][System.String]$Message)

    $logDir = Split-Path -Path $LogPath -Parent
    if (-not (Test-Path -LiteralPath $logDir))
    {
        New-Item -Path $logDir -ItemType Directory -Force | Out-Null
    }
    $line = "[{0}] {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message
    Add-Content -LiteralPath $LogPath -Value $line -Encoding UTF8
}

try
{
    if (-not (Test-Path -LiteralPath $RebootWatcherRegKey))
    {
        New-Item -Path $RebootWatcherRegKey -Force | Out-Null
    }

    $config = Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json

    $lastBoot = (Get-CimInstance -ClassName Win32_OperatingSystem).LastBootUpTime
    $uptime = (Get-Date) - $lastBoot
    $uptimeDays = [Math]::Floor($uptime.TotalDays)

    Write-Log "Uptime: $($uptime.ToString('dd\.hh\:mm\:ss')) ($uptimeDays days). Warning threshold: $($config.WarningThresholdDays)d, force-reboot threshold: $($config.ForceRebootThresholdDays)d."

    Set-ItemProperty -Path $RebootWatcherRegKey -Name 'UptimeDays' -Value $uptimeDays -Type DWord
    Set-ItemProperty -Path $RebootWatcherRegKey -Name 'LastCheckedUtc' -Value ((Get-Date).ToUniversalTime().ToString('o')) -Type String

    # Fresh boot (or uptime otherwise below the warning threshold): clear any
    # leftover state from a previous, now-irrelevant uptime cycle.
    if ($uptimeDays -lt $config.WarningThresholdDays)
    {
        Remove-ItemProperty -Path $RebootWatcherRegKey -Name 'ForceRebootScheduledUtc' -ErrorAction SilentlyContinue
        Set-ItemProperty -Path $RebootWatcherRegKey -Name 'WarningActive' -Value 0 -Type DWord
        Write-Log 'Below warning threshold - state cleared, no action.'
        return
    }

    if ($uptimeDays -ge $config.ForceRebootThresholdDays)
    {
        $scheduledRaw = (Get-ItemProperty -Path $RebootWatcherRegKey -Name 'ForceRebootScheduledUtc' -ErrorAction SilentlyContinue).ForceRebootScheduledUtc
        $alreadyScheduled = $false
        if ($scheduledRaw)
        {
            $scheduledAt = [DateTime]::Parse($scheduledRaw, $null, [System.Globalization.DateTimeStyles]::RoundtripKind)
            $secondsSinceScheduled = ((Get-Date).ToUniversalTime() - $scheduledAt).TotalSeconds
            # Safety net: if the scheduled restart should already have happened
            # (delay + a generous buffer) but uptime is still climbing, the
            # restart was evidently aborted - re-issue it rather than leaving the
            # device stuck past the threshold indefinitely.
            $alreadyScheduled = $secondsSinceScheduled -lt ($config.ForceRebootDelaySeconds + 3600)
        }

        if (-not $alreadyScheduled)
        {
            $message = [String]::Format($config.ForceRebootMessage, $uptimeDays)
            Write-Log "Force-reboot threshold reached. Issuing shutdown.exe /r /t $($config.ForceRebootDelaySeconds) /c `"$message`""
            & "$env:WinDir\System32\shutdown.exe" /r /t $config.ForceRebootDelaySeconds /c $message /f
            Set-ItemProperty -Path $RebootWatcherRegKey -Name 'ForceRebootScheduledUtc' -Value ((Get-Date).ToUniversalTime().ToString('o')) -Type String
        }
        else
        {
            Write-Log 'Force reboot already scheduled and still within its delay window - not re-issuing.'
        }

        Set-ItemProperty -Path $RebootWatcherRegKey -Name 'WarningActive' -Value 1 -Type DWord
        return
    }

    # Between the warning and force-reboot thresholds: flag it for the
    # interactive-user notification task, but take no action ourselves.
    Set-ItemProperty -Path $RebootWatcherRegKey -Name 'WarningActive' -Value 1 -Type DWord
    Write-Log 'Warning threshold reached - flagged for tray notification.'
}
catch
{
    Write-Log "ERROR: $($_.Exception.Message)"
    throw
}
