<#

.SYNOPSIS
PSAppDeployToolkit - This script performs the installation or uninstallation of an application(s).

.DESCRIPTION
- The script is provided as a template to perform an install, uninstall, or repair of an application(s).
- The script either performs an "Install", "Uninstall", or "Repair" deployment type.
- The install deployment type is broken down into 3 main sections/phases: Pre-Install, Install, and Post-Install.

The script imports the PSAppDeployToolkit module which contains the logic and functions required to install or uninstall an application.

Deploys the Adobe Creative Cloud Desktop app (the launcher only - not individual
creative apps like Photoshop) as a Win32 app instead of the native "Microsoft Store"
(winget) app type, for sec.device.windows.selfdeploy. Unlike Firefox/Office, the
native Creative Cloud winGetApp already installs in SYSTEM context and isn't
individually broken - this exists purely per the tenant's broader policy of avoiding
msstore/winget app types generally, which have hit ESP/context problems elsewhere.
Individual creative apps (Photoshop etc.) still require the user to sign in with
their personal Adobe license and install per-app afterward - this tenant's licenses
are individual/nonprofit-discounted, not Teams/Enterprise Admin Console-managed, so
there is no way to pre-license or silently pre-install specific creative apps.

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
    AppVendor = 'Adobe'
    AppName = 'Creative Cloud Desktop (Win32)'
    AppVersion = '6.10.0.252'
    AppArch = 'x64'
    AppLang = 'EN'
    AppRevision = '01'
    AppSuccessExitCodes = @(0)
    AppRebootExitCodes = @(1641, 3010)
    AppProcessesToClose = @()
    AppScriptVersion = '6.10.0.252'
    AppScriptDate = '2026-08-30'
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
# AppVersion above is this *wrapper package's* own version, matching the Creative
# Cloud Desktop build it currently ships (6.10.0.252) - not to be confused with
# whatever version Creative Cloud Desktop itself later auto-updates to on the device
# (it updates itself independently once installed; this marker only reflects what
# this package last deployed, same convention as every other app in this repo).
$CCInstallRegKey = 'HKLM:\SOFTWARE\Organization\CreativeCloudWin32'
$CCSetupExeName = 'Set-up.exe'
# Adobe's documented enterprise uninstall path for Creative Cloud Desktop - the
# ADC/AAM common installer engine ("HDBox") shipped by every Creative Cloud Desktop
# install. Not yet exercised against a real device in this tenant - verify on first
# real uninstall.
$CCUninstallerPath = 'C:\Program Files\Common Files\Adobe\Adobe Desktop Common\HDBox\Setup.exe'


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

    ## This is a background, unattended Required install on devices with no signed-in
    ## user (self-deploying Autopilot) - there's nobody there to see a dialog, so
    ## Show-ADTInstallationWelcome is intentionally not called here.


    ##================================================
    ## MARK: Install
    ##================================================
    $adtSession.InstallPhase = $adtSession.DeploymentType

    # --silent is Adobe's documented enterprise/unattended switch for this ESD-style
    # bootstrapper (the same switch Adobe Admin Console package exports produce) -
    # there is no UI to suppress beyond this.
    $setupPath = Join-Path $adtSession.DirSupportFiles $CCSetupExeName
    Write-ADTLogEntry -Message "Installing Creative Cloud Desktop from '$setupPath'."
    Start-ADTProcess -FilePath $setupPath -ArgumentList '--silent' -WindowStyle Hidden


    ##================================================
    ## MARK: Post-Install
    ##================================================
    $adtSession.InstallPhase = "Post-$($adtSession.DeploymentType)"

    # Only written once Start-ADTProcess has returned without throwing - PSADT treats
    # a non-success exit code as a terminating error, so a genuinely failed install
    # never reaches this line and the marker stays unset.
    Set-ADTRegistryKey -Key $CCInstallRegKey -Name 'Version' -Value $adtSession.AppVersion -Type String
    Write-ADTLogEntry -Message "Creative Cloud Desktop install completed. Marker key written."
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

    if (Test-Path -LiteralPath $CCUninstallerPath)
    {
        Write-ADTLogEntry -Message "Uninstalling Creative Cloud Desktop via '$CCUninstallerPath'."
        Start-ADTProcess -FilePath $CCUninstallerPath -ArgumentList '--uninstall --silent' -WindowStyle Hidden
    }
    else
    {
        Write-ADTLogEntry -Message "Creative Cloud Desktop uninstaller not found at '$CCUninstallerPath' - assuming already removed." -Severity 2
    }


    ##================================================
    ## MARK: Post-Uninstallation
    ##================================================
    $adtSession.InstallPhase = "Post-$($adtSession.DeploymentType)"

    if (Test-Path -LiteralPath $CCInstallRegKey)
    {
        Remove-ADTRegistryKey -Key $CCInstallRegKey -Recurse
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
    $adtSession.InstallPhase = $adtSession.DeploymentType

    $setupPath = Join-Path $adtSession.DirSupportFiles $CCSetupExeName
    Start-ADTProcess -FilePath $setupPath -ArgumentList '--silent' -WindowStyle Hidden
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
