<#

.SYNOPSIS
PSAppDeployToolkit - This script performs the installation or uninstallation of an application(s).

.DESCRIPTION
- The script is provided as a template to perform an install, uninstall, or repair of an application(s).
- The script either performs an "Install", "Uninstall", or "Repair" deployment type.
- The install deployment type is broken down into 3 main sections/phases: Pre-Install, Install, and Post-Install.

The script imports the PSAppDeployToolkit module which contains the logic and functions required to install or uninstall an application.

This deployment is a background infrastructure framework rather than a traditional
application install: it deploys a worker script and a scheduled task that creates
managed shortcuts on the Public Desktop at every user logon. See SupportFiles\New-Shortcuts.ps1
and README.md for the framework's behavior.

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
    AppName = 'Desktop Shortcut Deployment'
    AppVersion = '1.1.3'
    AppArch = ''
    AppLang = 'EN'
    AppRevision = '01'
    AppSuccessExitCodes = @(0)
    AppRebootExitCodes = @(1641, 3010)
    AppProcessesToClose = @()
    AppScriptVersion = '1.1.3'
    AppScriptDate = '2026-07-23'
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
# Uses an ASCII-safe slug (no spaces/diacritics) for filesystem/registry/task
# names, to sidestep any encoding or quoting edge cases in Scheduled Tasks/Registry.
$ShortcutFrameworkInstallDir = Join-Path $env:ProgramData 'LundsFontanhus\ShortcutDeployment'
$ShortcutFrameworkScriptFileName = 'New-Shortcuts.ps1'
$ShortcutFrameworkConfigFileName = 'Shortcuts.json'
$ShortcutFrameworkIconFolderName = 'Icons'
# ASCII-only task name (no diacritics). The scheduled-task name is an identifier used
# for Get/Register/Unregister/Start; a non-ASCII "ä" here proved fragile because this
# script is read as ANSI when it lacks a UTF-8 BOM, mangling the name and leaving the
# register/replace cycle without a working task. Keep this ASCII regardless of file
# encoding, matching the ASCII slug already used for the install dir and registry key.
$ShortcutFrameworkTaskName = 'Lunds Fontanhus - Deploy Desktop Shortcuts'
$ShortcutFrameworkRegKey = 'HKLM:\SOFTWARE\LundsFontanhus\ShortcutDeployment'


function Register-ShortcutScheduledTask
{
    <#
        "At log on" with no -User parameter fires for ANY interactive logon on the
        machine. Running as SYSTEM (S-1-5-18) with LogonType ServiceAccount puts the
        task in Session 0, which has no desktop to render to - so it is inherently
        invisible with no window flash, independent of -WindowStyle Hidden.
    #>
    $powershellExe = Join-Path $env:WinDir 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $scriptPath    = Join-Path $ShortcutFrameworkInstallDir $ShortcutFrameworkScriptFileName
    $configPath    = Join-Path $ShortcutFrameworkInstallDir $ShortcutFrameworkConfigFileName
    $iconDirPath   = Join-Path $ShortcutFrameworkInstallDir $ShortcutFrameworkIconFolderName
    # Pass every path explicitly so the worker never has to fall back to its
    # script-relative defaults (which depend on $PSScriptRoot at run time).
    $arguments     = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$scriptPath`" -ConfigPath `"$configPath`" -IconDir `"$iconDirPath`""

    $action    = New-ScheduledTaskAction -Execute $powershellExe -Argument $arguments
    $trigger   = New-ScheduledTaskTrigger -AtLogOn
    $trigger.Delay = 'PT30S'  # let the profile/Explorer finish loading before we look for it
    $principal = New-ScheduledTaskPrincipal -UserId 'S-1-5-18' -LogonType ServiceAccount -RunLevel Highest
    $settings  = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
                    -Hidden -StartWhenAvailable -MultipleInstances IgnoreNew `
                    -ExecutionTimeLimit (New-TimeSpan -Minutes 15)

    if (Get-ScheduledTask -TaskName $ShortcutFrameworkTaskName -ErrorAction SilentlyContinue)
    {
        Write-ADTLogEntry -Message "Scheduled task '$ShortcutFrameworkTaskName' already exists; replacing it."
        Unregister-ScheduledTask -TaskName $ShortcutFrameworkTaskName -Confirm:$false
    }

    Register-ScheduledTask -TaskName $ShortcutFrameworkTaskName -Action $action -Trigger $trigger `
        -Principal $principal -Settings $settings `
        -Description 'Creates managed shortcuts on the Public Desktop for the logged-on user. Deployed by Lunds Fontanhus IT.' | Out-Null

    # Sanity check: confirm the task is queryable after registration. If it is not,
    # throw so the install fails visibly and Intune retries/reports it, instead of
    # reporting success while nothing would run at logon.
    if (-not (Get-ScheduledTask -TaskName $ShortcutFrameworkTaskName -ErrorAction SilentlyContinue))
    {
        throw "Scheduled task '$ShortcutFrameworkTaskName' was not present after registration."
    }

    Write-ADTLogEntry -Message "Scheduled task '$ShortcutFrameworkTaskName' registered and verified (runs as SYSTEM, At Log On, any user)."
}

function Remove-ManagedShortcuts
{
    # Mirrors the filename sanitization the worker script uses, so uninstall
    # removes exactly the files that were (or would have been) created.
    $configPath = Join-Path $ShortcutFrameworkInstallDir $ShortcutFrameworkConfigFileName
    if (-not (Test-Path -LiteralPath $configPath)) { return }

    try
    {
        $shortcutDefs = Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json
    }
    catch
    {
        Write-ADTLogEntry -Message "Could not parse '$configPath' during uninstall cleanup: $($_.Exception.Message)" -Severity 2
        return
    }

    $publicDesktop = Join-Path $env:Public 'Desktop'
    foreach ($def in $shortcutDefs)
    {
        $safeName  = $def.Name -replace '[\\/:*?"<>|]', '_'
        $extension = if ($def.Type -eq 'Url') { 'url' } else { 'lnk' }
        $linkPath  = Join-Path $publicDesktop "$safeName.$extension"
        if (Test-Path -LiteralPath $linkPath)
        {
            Write-ADTLogEntry -Message "Removing managed shortcut '$linkPath'."
            Remove-ADTFile -Path $linkPath
        }
    }
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
    ## for this background infrastructure deployment, so Show-ADTInstallationWelcome
    ## and Show-ADTInstallationProgress are intentionally not called.


    ##================================================
    ## MARK: Install
    ##================================================
    $adtSession.InstallPhase = $adtSession.DeploymentType

    Write-ADTLogEntry -Message "Deploying shortcut framework files to '$ShortcutFrameworkInstallDir'."
    if (-not (Test-Path -LiteralPath $ShortcutFrameworkInstallDir))
    {
        New-Item -Path $ShortcutFrameworkInstallDir -ItemType Directory -Force | Out-Null
    }
    Copy-ADTFile -Path "$($adtSession.DirSupportFiles)\$ShortcutFrameworkScriptFileName" -Destination $ShortcutFrameworkInstallDir
    Copy-ADTFile -Path "$($adtSession.DirSupportFiles)\$ShortcutFrameworkConfigFileName" -Destination $ShortcutFrameworkInstallDir

    # Persist any bundled icons (SupportFiles\Icons\*) to the install dir so a Url
    # entry's IconFile can reference a package-shipped icon by bare filename. This
    # is optional - the folder only exists if icons were added to the package.
    $iconSource = Join-Path $adtSession.DirSupportFiles $ShortcutFrameworkIconFolderName
    if (Test-Path -LiteralPath $iconSource)
    {
        $iconDest = Join-Path $ShortcutFrameworkInstallDir $ShortcutFrameworkIconFolderName
        if (-not (Test-Path -LiteralPath $iconDest))
        {
            New-Item -Path $iconDest -ItemType Directory -Force | Out-Null
        }
        Write-ADTLogEntry -Message "Deploying bundled icons to '$iconDest'."
        Copy-ADTFile -Path "$iconSource\*" -Destination $iconDest -Recurse
    }


    ##================================================
    ## MARK: Post-Install
    ##================================================
    $adtSession.InstallPhase = "Post-$($adtSession.DeploymentType)"

    Register-ShortcutScheduledTask
    Set-ADTRegistryKey -Key $ShortcutFrameworkRegKey -Name 'Version' -Value $adtSession.AppVersion -Type String

    # Run once immediately so whoever is logged on right now gets their
    # shortcuts without needing to log off/on.
    Start-ScheduledTask -TaskName $ShortcutFrameworkTaskName -ErrorAction SilentlyContinue
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

    if (Get-ScheduledTask -TaskName $ShortcutFrameworkTaskName -ErrorAction SilentlyContinue)
    {
        Write-ADTLogEntry -Message "Removing scheduled task '$ShortcutFrameworkTaskName'."
        Unregister-ScheduledTask -TaskName $ShortcutFrameworkTaskName -Confirm:$false
    }

    Remove-ManagedShortcuts


    ##================================================
    ## MARK: Post-Uninstallation
    ##================================================
    $adtSession.InstallPhase = "Post-$($adtSession.DeploymentType)"

    Remove-ADTFolder -Path $ShortcutFrameworkInstallDir
    if (Test-Path -LiteralPath $ShortcutFrameworkRegKey)
    {
        Remove-ADTRegistryKey -Key $ShortcutFrameworkRegKey -Recurse
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
