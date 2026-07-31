<#

.SYNOPSIS
PSAppDeployToolkit - This script performs the installation or uninstallation of an application(s).

.DESCRIPTION
- The script is provided as a template to perform an install, uninstall, or repair of an application(s).
- The script either performs an "Install", "Uninstall", or "Repair" deployment type.
- The install deployment type is broken down into 3 main sections/phases: Pre-Install, Install, and Post-Install.

The script imports the PSAppDeployToolkit module which contains the logic and functions required to install or uninstall an application.

This deployment is a background reporting framework rather than a traditional
application install: it deploys a worker script and a weekly scheduled task that
collects hardware details Microsoft Graph does not expose for Intune-managed Windows
devices (CPU model, GPU, primary disk model/type) and reports them to the Dashhouse
Admin UI. See SupportFiles\Get-DeviceInventory.ps1 and README.md for the framework's
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
    AppVendor = 'Organization'
    AppName = 'Device Inventory Report'
    AppVersion = '2.0.0'
    AppArch = ''
    AppLang = 'EN'
    AppRevision = '01'
    AppSuccessExitCodes = @(0)
    AppRebootExitCodes = @(1641, 3010)
    AppProcessesToClose = @()
    AppScriptVersion = '2.0.0'
    AppScriptDate = '2026-07-31'
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
# Uses an ASCII-safe slug (no spaces/diacritics) for filesystem/registry/task names,
# to sidestep any encoding or quoting edge cases in Scheduled Tasks/Registry - same
# reasoning as the other apps in this repo.
$DeviceInventoryInstallDir = Join-Path $env:ProgramData 'Organization\DeviceInventory'
$DeviceInventoryScriptFileName = 'Get-DeviceInventory.ps1'
$DeviceInventoryConfigFileName = 'DeviceInventoryConfig.json'
$DeviceInventoryTaskName = 'Organization - Device Inventory Report'
$DeviceInventoryRegKey = 'HKLM:\SOFTWARE\Organization\DeviceInventory'


function Register-DeviceInventoryScheduledTask
{
    <#
        Weekly (Monday, 04:30 local time, up to 1h random delay so a whole fleet
        doesn't hit the ingest endpoint at once). Hardware identity (CPU/GPU/disk
        model) changes rarely, so a daily cadence like the sync/profile-cleanup jobs
        would be wasted work - weekly is enough to catch hardware swaps and pick up
        newly enrolled devices promptly via the run-once-on-install below.

        Runs as SYSTEM (S-1-5-18): dsregcmd /status and the CIM hardware queries used
        here don't strictly require it, but SYSTEM keeps this consistent with the
        other background maintenance tasks in this repo and avoids any dependency on
        a user being signed in.
    #>
    $powershellExe = Join-Path $env:WinDir 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $scriptPath    = Join-Path $DeviceInventoryInstallDir $DeviceInventoryScriptFileName
    $configPath    = Join-Path $DeviceInventoryInstallDir $DeviceInventoryConfigFileName
    $arguments     = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$scriptPath`" -ConfigPath `"$configPath`""

    $action    = New-ScheduledTaskAction -Execute $powershellExe -Argument $arguments
    $trigger   = New-ScheduledTaskTrigger -Weekly -DaysOfWeek Monday -At '04:30'
    $trigger.RandomDelay = 'PT1H'
    $principal = New-ScheduledTaskPrincipal -UserId 'S-1-5-18' -LogonType ServiceAccount -RunLevel Highest
    $settings  = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
                    -Hidden -StartWhenAvailable -MultipleInstances IgnoreNew `
                    -ExecutionTimeLimit (New-TimeSpan -Minutes 15)

    if (Get-ScheduledTask -TaskName $DeviceInventoryTaskName -ErrorAction SilentlyContinue)
    {
        Write-ADTLogEntry -Message "Scheduled task '$DeviceInventoryTaskName' already exists; replacing it."
        Unregister-ScheduledTask -TaskName $DeviceInventoryTaskName -Confirm:$false
    }

    Register-ScheduledTask -TaskName $DeviceInventoryTaskName -Action $action -Trigger $trigger `
        -Principal $principal -Settings $settings `
        -Description 'Reports CPU/GPU/disk hardware details to Dashhouse that Intune/Graph does not expose. Deployed by Organization IT.' | Out-Null

    # Sanity check: confirm the task is queryable after registration. If it is not,
    # throw so the install fails visibly and Intune retries/reports it, instead of
    # reporting success while nothing would run on schedule.
    if (-not (Get-ScheduledTask -TaskName $DeviceInventoryTaskName -ErrorAction SilentlyContinue))
    {
        throw "Scheduled task '$DeviceInventoryTaskName' was not present after registration."
    }

    Write-ADTLogEntry -Message "Scheduled task '$DeviceInventoryTaskName' registered and verified (runs as SYSTEM, weekly Monday 04:30 + up to 1h random delay)."
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
    ## for this background reporting deployment, so Show-ADTInstallationWelcome
    ## and Show-ADTInstallationProgress are intentionally not called.


    ##================================================
    ## MARK: Install
    ##================================================
    $adtSession.InstallPhase = $adtSession.DeploymentType

    Write-ADTLogEntry -Message "Deploying device inventory reporting files to '$DeviceInventoryInstallDir'."
    if (-not (Test-Path -LiteralPath $DeviceInventoryInstallDir))
    {
        New-Item -Path $DeviceInventoryInstallDir -ItemType Directory -Force | Out-Null
    }
    Copy-ADTFile -Path "$($adtSession.DirSupportFiles)\$DeviceInventoryScriptFileName" -Destination $DeviceInventoryInstallDir
    Copy-ADTFile -Path "$($adtSession.DirSupportFiles)\$DeviceInventoryConfigFileName" -Destination $DeviceInventoryInstallDir


    ##================================================
    ## MARK: Post-Install
    ##================================================
    $adtSession.InstallPhase = "Post-$($adtSession.DeploymentType)"

    Register-DeviceInventoryScheduledTask
    Set-ADTRegistryKey -Key $DeviceInventoryRegKey -Name 'Version' -Value $adtSession.AppVersion -Type String

    # Run once immediately so a newly enrolled or newly updated device reports in
    # right away rather than waiting up to a week for the next scheduled run.
    Start-ScheduledTask -TaskName $DeviceInventoryTaskName -ErrorAction SilentlyContinue
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

    if (Get-ScheduledTask -TaskName $DeviceInventoryTaskName -ErrorAction SilentlyContinue)
    {
        Write-ADTLogEntry -Message "Removing scheduled task '$DeviceInventoryTaskName'."
        Unregister-ScheduledTask -TaskName $DeviceInventoryTaskName -Confirm:$false
    }


    ##================================================
    ## MARK: Post-Uninstallation
    ##================================================
    $adtSession.InstallPhase = "Post-$($adtSession.DeploymentType)"

    Remove-ADTFolder -Path $DeviceInventoryInstallDir
    if (Test-Path -LiteralPath $DeviceInventoryRegKey)
    {
        Remove-ADTRegistryKey -Key $DeviceInventoryRegKey -Recurse
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
    # re-copy the current files, re-register the scheduled task, and re-run it.
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
