<#

.SYNOPSIS
PSAppDeployToolkit - This script performs the installation or uninstallation of an application(s).

.DESCRIPTION
- The script is provided as a template to perform an install, uninstall, or repair of an application(s).
- The script either performs an "Install", "Uninstall", or "Repair" deployment type.
- The install deployment type is broken down into 3 main sections/phases: Pre-Install, Install, and Post-Install.

The script imports the PSAppDeployToolkit module which contains the logic and functions required to install or uninstall an application.

This deployment is a background monitoring framework rather than a traditional
application install: it deploys two worker scripts and two scheduled tasks that
watch the device's uptime and, per RebootWatcherConfig.json's thresholds, warn the
signed-in user with a systray notification and - if uptime keeps climbing - force a
restart with a 10-minute countdown. See SupportFiles\Invoke-RebootWatcherCheck.ps1,
SupportFiles\Show-RebootWatcherNotification.ps1, and README.md for the framework's
behavior.

.PARAMETER DeploymentType
The type of deployment to perform.

.PARAMETER DeployMode
Specifies whether the installation should be run in Interactive (shows dialogs), Silent (no dialogs), NonInteractive (dialogs without prompts) mode, or Auto (shows dialogs if a user is logged on, device is not in the OOBE, and there's no running apps to close).

Silent mode is automatically set if it is detected that the process is not user interactive, no users are logged on, the device is in Autopilot mode, or there's specified processes to close that are currently running.

.PARAMETER SuppressRebootPassThru
Suppresses the 3010 return code (requires restart) from being passed back to the parent process (e.g. SCCM) if detected from an installation. If 3010 is passed back to SCCM, a reboot prompt will be triggered.

.PARAMETER TerminalServerMode
Changes to "user install mode" and back to "user execute mode" for installing/uninstalling applications for Remote Desktop Session Hosts/Citrix servers.

.PARAMETER DisableLogging
Disables logging to file for the script.

.EXAMPLE
powershell.exe -File Invoke-AppDeployToolkit.ps1

.EXAMPLE
powershell.exe -File Invoke-AppDeployToolkit.ps1 -DeployMode Silent

.EXAMPLE
powershell.exe -File Invoke-AppDeployToolkit.ps1 -DeploymentType Uninstall

.EXAMPLE
Invoke-AppDeployToolkit.exe -DeploymentType Install -DeployMode Silent

.INPUTS
None. You cannot pipe objects to this script.

.OUTPUTS
None. This script does not generate any output.

.NOTES
Toolkit Exit Code Ranges:
- 60000 - 68999: Reserved for built-in exit codes in Invoke-AppDeployToolkit.ps1, and Invoke-AppDeployToolkit.exe
- 69000 - 69999: Recommended for user customized exit codes in Invoke-AppDeployToolkit.ps1
- 70000 - 79999: Recommended for user customized exit codes in PSAppDeployToolkit.Extensions module.

.LINK
https://psappdeploytoolkit.com

#>

[CmdletBinding()]
param
(
    # Default is 'Install'.
    [Parameter(Mandatory = $false)]
    [ValidateSet('Install', 'Uninstall', 'Repair')]
    [System.String]$DeploymentType,

    # Default is 'Auto'. Don't hard-code this unless required.
    [Parameter(Mandatory = $false)]
    [ValidateSet('Auto', 'Interactive', 'NonInteractive', 'Silent')]
    [System.String]$DeployMode,

    [Parameter(Mandatory = $false)]
    [System.Management.Automation.SwitchParameter]$SuppressRebootPassThru,

    [Parameter(Mandatory = $false)]
    [System.Management.Automation.SwitchParameter]$TerminalServerMode,

    [Parameter(Mandatory = $false)]
    [System.Management.Automation.SwitchParameter]$DisableLogging
)


##================================================
## MARK: Variables
##================================================

# Zero-Config MSI support is provided when "AppName" is null or empty.
# By setting the "AppName" property, Zero-Config MSI will be disabled.
# This framework never uses Zero-Config MSI - AppName is always set.
$adtSession = @{
    # App variables.
    AppVendor = 'Lunds Fontänhus'
    AppName = 'Reboot Watcher'
    AppVersion = '1.0.1'
    AppArch = ''
    AppLang = 'EN'
    AppRevision = '01'
    AppSuccessExitCodes = @(0)
    AppRebootExitCodes = @(1641, 3010)
    AppProcessesToClose = @()
    AppScriptVersion = '1.0.1'
    AppScriptDate = '2026-08-23'
    AppScriptAuthor = ''
    RequireAdmin = $true

    # Install Titles (Only set here to override defaults set by the toolkit).
    InstallName = ''
    InstallTitle = ''

    # Script variables.
    DeployAppScriptFriendlyName = $MyInvocation.MyCommand.Name
    DeployAppScriptParameters = $PSBoundParameters
    DeployAppScriptVersion = '4.1.8'
}

# Framework-specific paths/names, shared by the functions below.
# Uses an ASCII-safe slug (no diacritics) for filesystem/registry/task names, matching
# the desktop-shortcuts app's reasoning: a script re-saved without a UTF-8 BOM is read
# as ANSI, which mangles non-ASCII characters and leaves the register/replace cycle
# without a working task.
$RebootWatcherInstallDir = Join-Path $env:ProgramData 'LundsFontanhus\RebootWatcher'
$RebootWatcherCheckScriptFileName = 'Invoke-RebootWatcherCheck.ps1'
$RebootWatcherNotifyScriptFileName = 'Show-RebootWatcherNotification.ps1'
$RebootWatcherConfigFileName = 'RebootWatcherConfig.json'
$RebootWatcherIconFileName = 'lundsfontan.ico'
$RebootWatcherCheckTaskName = 'Lunds Fontanhus - Reboot Watcher Check'
$RebootWatcherNotifyTaskName = 'Lunds Fontanhus - Reboot Watcher Notify'
$RebootWatcherRegKey = 'HKLM:\SOFTWARE\LundsFontanhus\RebootWatcher'


function Register-RebootWatcherCheckScheduledTask
{
    <#
        Runs as SYSTEM (S-1-5-18) so the forced restart at the 30-day threshold works
        even if no one is signed in, and so shutdown.exe's own countdown notice - which
        is rendered at the system level regardless of which session issued it - reaches
        whichever user is signed in. Hourly so a device that crosses either threshold
        is caught within an hour, not up to a day later.

        A single "Once, starting now" trigger with an indefinite hourly repetition
        (rather than -Daily/-At) both runs the first check immediately at install and
        keeps repeating forever - Register-ScheduledTask has no direct "run every N
        hours forever" trigger shape, this is the standard workaround.
    #>
    $powershellExe = Join-Path $env:WinDir 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $scriptPath    = Join-Path $RebootWatcherInstallDir $RebootWatcherCheckScriptFileName
    $configPath    = Join-Path $RebootWatcherInstallDir $RebootWatcherConfigFileName
    $arguments     = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$scriptPath`" -ConfigPath `"$configPath`""

    $action    = New-ScheduledTaskAction -Execute $powershellExe -Argument $arguments
    $trigger   = New-ScheduledTaskTrigger -Once -At (Get-Date)
    $trigger.Repetition.Interval = 'PT1H'
    $trigger.Repetition.Duration = ''
    $principal = New-ScheduledTaskPrincipal -UserId 'S-1-5-18' -LogonType ServiceAccount -RunLevel Highest
    $settings  = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
                    -Hidden -StartWhenAvailable -MultipleInstances IgnoreNew `
                    -ExecutionTimeLimit (New-TimeSpan -Minutes 5)

    if (Get-ScheduledTask -TaskName $RebootWatcherCheckTaskName -ErrorAction SilentlyContinue)
    {
        Write-ADTLogEntry -Message "Scheduled task '$RebootWatcherCheckTaskName' already exists; replacing it."
        Unregister-ScheduledTask -TaskName $RebootWatcherCheckTaskName -Confirm:$false
    }

    Register-ScheduledTask -TaskName $RebootWatcherCheckTaskName -Action $action -Trigger $trigger `
        -Principal $principal -Settings $settings `
        -Description 'Checks device uptime hourly and forces a restart (10 min countdown) past the configured threshold, for security reasons. Deployed by Lunds Fontanhus IT.' | Out-Null

    # Sanity check: confirm the task is queryable after registration. If it is not,
    # throw so the install fails visibly and Intune retries/reports it, instead of
    # reporting success while nothing would run on schedule.
    if (-not (Get-ScheduledTask -TaskName $RebootWatcherCheckTaskName -ErrorAction SilentlyContinue))
    {
        throw "Scheduled task '$RebootWatcherCheckTaskName' was not present after registration."
    }

    Write-ADTLogEntry -Message "Scheduled task '$RebootWatcherCheckTaskName' registered and verified (runs as SYSTEM, hourly)."
}

function Register-RebootWatcherNotifyScheduledTask
{
    <#
        Unlike the check task above, this one must run inside the interactive user's
        own session - System.Windows.Forms.NotifyIcon has no way to raise a systray
        balloon into a session it isn't running in, and Session 0 (where a SYSTEM task
        runs) has no desktop to render one on at all. -GroupId 'BUILTIN\Users' with
        LogonType Group runs the task as whichever user triggers it, in their own
        session, without needing to hard-code a specific user account.

        Triggered at logon (so a user who's been signed in for days still gets caught
        promptly after their next logon) plus an indefinite 4-hour repetition, so a
        long-running session without a logoff/logon cycle still gets periodic reminders
        once the warning threshold is active.
    #>
    $powershellExe = Join-Path $env:WinDir 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $scriptPath    = Join-Path $RebootWatcherInstallDir $RebootWatcherNotifyScriptFileName
    $configPath    = Join-Path $RebootWatcherInstallDir $RebootWatcherConfigFileName
    $iconPath      = Join-Path $RebootWatcherInstallDir $RebootWatcherIconFileName
    $arguments     = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$scriptPath`" -ConfigPath `"$configPath`" -IconPath `"$iconPath`""

    $action    = New-ScheduledTaskAction -Execute $powershellExe -Argument $arguments
    $trigger   = New-ScheduledTaskTrigger -AtLogOn
    $trigger.Delay = 'PT1M'  # let the profile/Explorer finish loading before the tray host is ready for a NotifyIcon
    $trigger.Repetition.Interval = 'PT4H'
    $trigger.Repetition.Duration = ''
    $principal = New-ScheduledTaskPrincipal -GroupId 'BUILTIN\Users' -LogonType Group -RunLevel Limited
    $settings  = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
                    -Hidden -StartWhenAvailable -MultipleInstances IgnoreNew `
                    -ExecutionTimeLimit (New-TimeSpan -Minutes 2)

    if (Get-ScheduledTask -TaskName $RebootWatcherNotifyTaskName -ErrorAction SilentlyContinue)
    {
        Write-ADTLogEntry -Message "Scheduled task '$RebootWatcherNotifyTaskName' already exists; replacing it."
        Unregister-ScheduledTask -TaskName $RebootWatcherNotifyTaskName -Confirm:$false
    }

    Register-ScheduledTask -TaskName $RebootWatcherNotifyTaskName -Action $action -Trigger $trigger `
        -Principal $principal -Settings $settings `
        -Description 'Shows a systray warning to the signed-in user once device uptime passes the warning threshold. Deployed by Lunds Fontanhus IT.' | Out-Null

    if (-not (Get-ScheduledTask -TaskName $RebootWatcherNotifyTaskName -ErrorAction SilentlyContinue))
    {
        throw "Scheduled task '$RebootWatcherNotifyTaskName' was not present after registration."
    }

    Write-ADTLogEntry -Message "Scheduled task '$RebootWatcherNotifyTaskName' registered and verified (runs as the logged-on user, at logon + every 4h)."
}

function Install-ADTDeployment
{
    [CmdletBinding()]
    param
    (
    )

    ##================================================
    ## MARK: Pre-Install
    ##================================================
    $adtSession.InstallPhase = "Pre-$($adtSession.DeploymentType)"

    ## No running processes need to close and nothing needs to be shown to the user
    ## for this background deployment, so Show-ADTInstallationWelcome and
    ## Show-ADTInstallationProgress are intentionally not called.


    ##================================================
    ## MARK: Install
    ##================================================
    $adtSession.InstallPhase = $adtSession.DeploymentType

    Write-ADTLogEntry -Message "Deploying Reboot Watcher files to '$RebootWatcherInstallDir'."
    if (-not (Test-Path -LiteralPath $RebootWatcherInstallDir))
    {
        New-Item -Path $RebootWatcherInstallDir -ItemType Directory -Force | Out-Null
    }
    Copy-ADTFile -Path "$($adtSession.DirSupportFiles)\$RebootWatcherCheckScriptFileName" -Destination $RebootWatcherInstallDir
    Copy-ADTFile -Path "$($adtSession.DirSupportFiles)\$RebootWatcherNotifyScriptFileName" -Destination $RebootWatcherInstallDir
    Copy-ADTFile -Path "$($adtSession.DirSupportFiles)\$RebootWatcherConfigFileName" -Destination $RebootWatcherInstallDir
    Copy-ADTFile -Path "$($adtSession.DirSupportFiles)\Icons\$RebootWatcherIconFileName" -Destination $RebootWatcherInstallDir


    ##================================================
    ## MARK: Post-Install
    ##================================================
    $adtSession.InstallPhase = "Post-$($adtSession.DeploymentType)"

    Register-RebootWatcherCheckScheduledTask
    Register-RebootWatcherNotifyScheduledTask
    Set-ADTRegistryKey -Key $RebootWatcherRegKey -Name 'Version' -Value $adtSession.AppVersion -Type String

    # Run the SYSTEM check task once immediately so a newly enrolled or newly updated
    # device evaluates its current uptime right away rather than waiting up to an hour.
    # The notify task is deliberately NOT force-started here - it needs to run inside
    # an interactive user's session, which generally doesn't exist during an Intune
    # push; it will pick up state on the next logon/repetition.
    Start-ScheduledTask -TaskName $RebootWatcherCheckTaskName -ErrorAction SilentlyContinue
}

function Uninstall-ADTDeployment
{
    [CmdletBinding()]
    param
    (
    )

    ##================================================
    ## MARK: Pre-Uninstall
    ##================================================
    $adtSession.InstallPhase = "Pre-$($adtSession.DeploymentType)"


    ##================================================
    ## MARK: Uninstall
    ##================================================
    $adtSession.InstallPhase = $adtSession.DeploymentType

    foreach ($taskName in @($RebootWatcherCheckTaskName, $RebootWatcherNotifyTaskName))
    {
        if (Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue)
        {
            Write-ADTLogEntry -Message "Removing scheduled task '$taskName'."
            Unregister-ScheduledTask -TaskName $taskName -Confirm:$false
        }
    }


    ##================================================
    ## MARK: Post-Uninstallation
    ##================================================
    $adtSession.InstallPhase = "Post-$($adtSession.DeploymentType)"

    Remove-ADTFolder -Path $RebootWatcherInstallDir
    if (Test-Path -LiteralPath $RebootWatcherRegKey)
    {
        Remove-ADTRegistryKey -Key $RebootWatcherRegKey -Recurse
    }
}

function Repair-ADTDeployment
{
    [CmdletBinding()]
    param
    (
    )

    ##================================================
    ## MARK: Repair
    ##================================================
    # A "repair" for this framework is just re-running the install logic:
    # re-copy the current files, re-register both scheduled tasks, and re-run the
    # check task once.
    $adtSession.InstallPhase = $adtSession.DeploymentType
    Install-ADTDeployment
}


##================================================
## MARK: Initialization
##================================================

# Set strict error handling across entire operation.
$ErrorActionPreference = [System.Management.Automation.ActionPreference]::Stop
$ProgressPreference = [System.Management.Automation.ActionPreference]::SilentlyContinue
Set-StrictMode -Version 1

# Import the module and instantiate a new session.
try
{
    # Import the module locally if available, otherwise try to find it from PSModulePath.
    if (Test-Path -LiteralPath "$PSScriptRoot\PSAppDeployToolkit\PSAppDeployToolkit.psd1" -PathType Leaf)
    {
        Get-ChildItem -LiteralPath "$PSScriptRoot\PSAppDeployToolkit" -Recurse -File | Unblock-File -ErrorAction Ignore
        Import-Module -FullyQualifiedName @{ ModuleName = "$PSScriptRoot\PSAppDeployToolkit\PSAppDeployToolkit.psd1"; Guid = '8c3c366b-8606-4576-9f2d-4051144f7ca2'; ModuleVersion = '4.1.8' } -Force
    }
    else
    {
        Import-Module -FullyQualifiedName @{ ModuleName = 'PSAppDeployToolkit'; Guid = '8c3c366b-8606-4576-9f2d-4051144f7ca2'; ModuleVersion = '4.1.8' } -Force
    }

    # Open a new deployment session, replacing $adtSession with a DeploymentSession.
    $iadtParams = Get-ADTBoundParametersAndDefaultValues -Invocation $MyInvocation
    $adtSession = Remove-ADTHashtableNullOrEmptyValues -Hashtable $adtSession
    $adtSession = Open-ADTSession @adtSession @iadtParams -PassThru
}
catch
{
    $Host.UI.WriteErrorLine((Out-String -InputObject $_ -Width ([System.Int32]::MaxValue)))
    exit 60008
}


##================================================
## MARK: Invocation
##================================================

# Commence the actual deployment operation.
try
{
    # Import any found extensions before proceeding with the deployment.
    Get-ChildItem -LiteralPath $PSScriptRoot -Directory | & {
        process
        {
            if ($_.Name -match 'PSAppDeployToolkit\..+$')
            {
                Get-ChildItem -LiteralPath $_.FullName -Recurse -File | Unblock-File -ErrorAction Ignore
                Import-Module -Name $_.FullName -Force
            }
        }
    }

    # Invoke the deployment and close out the session.
    & "$($adtSession.DeploymentType)-ADTDeployment"
    Close-ADTSession
}
catch
{
    # An unhandled error has been caught.
    $mainErrorMessage = "An unhandled error within [$($MyInvocation.MyCommand.Name)] has occurred.`n$(Resolve-ADTErrorRecord -ErrorRecord $_)"
    Write-ADTLogEntry -Message $mainErrorMessage -Severity 3

    ## Error details hidden from the user by default. Show a simple dialog with full stack trace:
    # Show-ADTDialogBox -Text $mainErrorMessage -Icon Stop -NoWait

    ## Or, a themed dialog with basic error message:
    # Show-ADTInstallationPrompt -Message "$($adtSession.DeploymentType) failed at line $($_.InvocationInfo.ScriptLineNumber), char $($_.InvocationInfo.OffsetInLine):`n$($_.InvocationInfo.Line.Trim())`n`nMessage:`n$($_.Exception.Message)" -ButtonRightText OK -Icon Error -NoWait

    Close-ADTSession -ExitCode 60001
}
