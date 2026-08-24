<#

.SYNOPSIS
PSAppDeployToolkit - This script performs the installation or uninstallation of an application(s).

.DESCRIPTION
- The script is provided as a template to perform an install, uninstall, or repair of an application(s).
- The script either performs an "Install", "Uninstall", or "Repair" deployment type.
- The install deployment type is broken down into 3 main sections/phases: Pre-Install, Install, and Post-Install.

The script imports the PSAppDeployToolkit module which contains the logic and functions required to install or uninstall an application.

This deployment installs the official HP Client Management Script Library (HP
CMSL) - HP's PowerShell module for managing HP BIOS/firmware and Softpaqs.
This app installs the module only: it never imports HPCMSL or invokes any of
its cmdlets itself. Deploying it here just makes the module available on the
device for other tooling/scripts that already expect it to be present.

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
    AppName = 'HP Client Management Script Library'
    AppVersion = '1.9.0'
    AppArch = ''
    AppLang = 'EN'
    AppRevision = '01'
    AppSuccessExitCodes = @(0)
    AppRebootExitCodes = @(1641, 3010)
    AppProcessesToClose = @()
    AppScriptVersion = '1.9.0'
    AppScriptDate = '2026-08-24'
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

# Framework-specific names, shared by the functions below. AppVersion above is
# an independent rollout counter, not the HP CMSL version - it's just the
# value written to the detection registry key and compared against Intune's
# displayVersion to decide whether to publish. Confirmed working end-to-end on
# a test device at 1.0.1; now at parity with the actual HP CMSL version this
# package ships (see HP_CMSL_INSTALLER_URL in build-and-publish.yml) - keep
# the two in lockstep going forward (bump AppVersion to match whenever the
# pinned installer URL/hash changes).
$HpCmslInstallerFileName = 'hp-cmsl-installer.exe'
$HpCmslDisplayName = 'HP Client Management Script Library'
$HpCmslRegKey = 'HKLM:\SOFTWARE\Organization\HPCMSL'


function Install-HpCmslScriptLibrary
{
    <#
        Installs the official HP CMSL package (an InnoSetup executable, not an
        MSI) silently. The installer itself deploys the HPCMSL module folders
        under the machine's PowerShell module paths (WindowsPowerShell and/or
        PowerShell 7, if present) - this function only runs HP's own installer
        with silent switches; it does not import or invoke the module itself.

        The installer is not committed to this repo - build-and-publish.yml
        downloads it from HP's official download endpoint, verifies it against
        a pinned SHA-256, and injects it into SupportFiles at build time (the
        same pattern used for the PSADT template). A locally hand-assembled
        test build (extracting the PSADT template yourself rather than letting
        CI do it) won't have it - that's expected, not a bug; see README.md.
    #>
    $installerPath = Join-Path $adtSession.DirSupportFiles $HpCmslInstallerFileName
    if (-not (Test-Path -LiteralPath $installerPath))
    {
        throw "HP CMSL installer '$HpCmslInstallerFileName' was not found in SupportFiles. This package must be built by CI, which injects it from HP's pinned, hash-verified download - see README.md."
    }

    Write-ADTLogEntry -Message "Installing HP Client Management Script Library $($adtSession.AppVersion) silently."
    Start-ADTProcess -FilePath $installerPath -ArgumentList '/VERYSILENT /SUPPRESSMSGBOXES /NORESTART' -WindowStyle Hidden
    Write-ADTLogEntry -Message 'HP Client Management Script Library installer completed.'
}

function Uninstall-HpCmslScriptLibrary
{
    <#
        HP CMSL's InnoSetup installer registers itself in the standard
        uninstall registry the same way any other Windows application does -
        Get-ADTApplication/Uninstall-ADTApplication (rather than a hard-coded
        uninstall path) is the correct PSADT way to drive an EXE-based
        installer's own uninstaller, since InnoSetup places it under a
        generated, version-specific folder that isn't safe to guess/hard-code.
    #>
    $installed = Get-ADTApplication -Name $HpCmslDisplayName -ErrorAction SilentlyContinue
    if ($installed)
    {
        foreach ($app in $installed)
        {
            Write-ADTLogEntry -Message "Removing '$($app.DisplayName)' $($app.DisplayVersion) via its registered uninstaller."
        }
        $installed | Uninstall-ADTApplication -ArgumentList '/VERYSILENT /SUPPRESSMSGBOXES /NORESTART'
    }
    else
    {
        Write-ADTLogEntry -Message 'HP Client Management Script Library is not present in the uninstall registry; nothing to remove.' -Severity 2
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
    ## for this silent module install, so Show-ADTInstallationWelcome and
    ## Show-ADTInstallationProgress are intentionally not called.


    ##================================================
    ## MARK: Install
    ##================================================
    $adtSession.InstallPhase = $adtSession.DeploymentType

    Install-HpCmslScriptLibrary


    ##================================================
    ## MARK: Post-Install
    ##================================================
    $adtSession.InstallPhase = "Post-$($adtSession.DeploymentType)"

    Set-ADTRegistryKey -Key $HpCmslRegKey -Name 'Version' -Value $adtSession.AppVersion -Type String
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

    Uninstall-HpCmslScriptLibrary


    ##================================================
    ## MARK: Post-Uninstallation
    ##================================================
    $adtSession.InstallPhase = "Post-$($adtSession.DeploymentType)"

    if (Test-Path -LiteralPath $HpCmslRegKey)
    {
        Remove-ADTRegistryKey -Key $HpCmslRegKey -Recurse
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
    # re-run HP's own installer (which is safe to run over an existing
    # install - InnoSetup handles that natively) and rewrite the version key.
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
