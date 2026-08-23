<#
.SYNOPSIS
Reboot Watcher - tray notification for the soft warning (runs as the logged-on user).

.DESCRIPTION
Reads the state written by Invoke-RebootWatcherCheck.ps1 (which runs as SYSTEM) from
HKLM:\SOFTWARE\LundsFontanhus\RebootWatcher - readable by any user, written only by
the SYSTEM task - and, if the warning threshold has been reached, shows a standard
Windows systray balloon notification telling the user to reboot for security reasons.

This script deliberately does nothing once the force-reboot threshold is reached:
at that point Invoke-RebootWatcherCheck.ps1 has already issued shutdown.exe /r with
a custom message, which shows Windows' own native countdown notice - a second,
separate balloon at that point would just be confusing.

.PARAMETER ConfigPath
Path to RebootWatcherConfig.json.

.PARAMETER IconPath
Path to the .ico file shown next to the balloon.
#>

[CmdletBinding()]
param
(
    [Parameter(Mandatory = $true)]
    [System.String]$ConfigPath,

    [Parameter(Mandatory = $true)]
    [System.String]$IconPath
)

$ErrorActionPreference = 'Stop'

$RebootWatcherRegKey = 'HKLM:\SOFTWARE\LundsFontanhus\RebootWatcher'

try
{
    $state = Get-ItemProperty -Path $RebootWatcherRegKey -ErrorAction SilentlyContinue
    if (-not $state -or $state.WarningActive -ne 1)
    {
        return
    }

    # Force-reboot threshold already handles its own native notification via
    # shutdown.exe /c - skip the balloon once a forced restart is in flight.
    if ($state.PSObject.Properties.Name -contains 'ForceRebootScheduledUtc')
    {
        return
    }

    $config = Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $uptimeDays = $state.UptimeDays
    $message = [String]::Format($config.BalloonMessage, $uptimeDays)

    Add-Type -AssemblyName System.Windows.Forms | Out-Null

    $notifyIcon = New-Object System.Windows.Forms.NotifyIcon
    try
    {
        $notifyIcon.Icon = if (Test-Path -LiteralPath $IconPath) { New-Object System.Drawing.Icon($IconPath) } else { [System.Drawing.SystemIcons]::Warning }
        $notifyIcon.Visible = $true
        $notifyIcon.BalloonTipIcon = [System.Windows.Forms.ToolTipIcon]::Warning
        $notifyIcon.BalloonTipTitle = $config.BalloonTitle
        $notifyIcon.BalloonTipText = $message
        $notifyIcon.ShowBalloonTip(15000)

        # Keep the icon (and thus the balloon) alive long enough to be seen;
        # ShowBalloonTip is fire-and-forget but disposing immediately can pull
        # the tray icon out from under it.
        Start-Sleep -Seconds 20
    }
    finally
    {
        $notifyIcon.Visible = $false
        $notifyIcon.Dispose()
    }
}
catch
{
    # Best-effort notification: never let a failure here surface as a visible
    # error to the interactive user it's running as.
    exit 0
}
