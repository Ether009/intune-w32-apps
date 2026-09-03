<#

.SYNOPSIS
PSAppDeployToolkit - This script performs the installation or uninstallation of an application(s).

.DESCRIPTION
Deploys the OneDrive Team Sync tool: a per-user logon task that keeps a user's synced OneDrive
Team libraries in line with their actual Team memberships (adds new ones, removes ones they've
lost access to), replacing the old "OneDrive Sync Setup" remediation script.

That old tool: (1) only ever added syncs, never removed stale ones after a Team rename/removal,
(2) ran with a visible console window, (3) hardcoded a Graph app client secret in plaintext in
the script body, (4) used odopen:// to add syncs, which pops a visible OneDrive window per
library - closing that window before it finishes cancels the add, and users at this org close
anything they don't recognize on sight. This replaces all of it: proper add/remove diffing,
a fully silent add path via OneDrive's own AutoMountTeamSites policy (no window at all), and
certificate-based app auth. The sync script runs as SYSTEM (that policy's registry path is
writable only by SYSTEM/Administrators, confirmed via a real ACL check - not even the user it
acts on behalf of can write it) and resolves the actual interactive user itself to act on their
behalf, rather than running in their own session.

This installer also actively removes any leftover copy of the old tool (C:\Scripts\odsetup.ps1
and its Startup-folder shortcut) from devices that picked it up before it was retired.

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

$adtSession = @{
    AppVendor = 'Organization'
    AppName = 'OneDrive Team Sync'
    AppVersion = '2.1.5'
    AppArch = 'x64'
    AppLang = 'EN'
    AppRevision = '01'
    AppSuccessExitCodes = @(0)
    AppRebootExitCodes = @(1641, 3010)
    AppProcessesToClose = @()
    AppScriptVersion = '2.1.5'
    AppScriptDate = '2026-08-31'
    AppScriptAuthor = ''
    RequireAdmin = $true

    InstallName = ''
    InstallTitle = ''

    DeployAppScriptFriendlyName = $MyInvocation.MyCommand.Name
    DeployAppScriptParameters = $PSBoundParameters
    DeployAppScriptVersion = '4.1.8'
}

$InstallDir = 'C:\Program Files\Organization\OneDriveTeamSync'
$ScriptDest = Join-Path $InstallDir 'Sync-OneDriveTeams.ps1'
$TaskName = 'OneDriveTeamSync'
$CertThumbprintRegKey = 'HKLM:\SOFTWARE\Organization\OneDriveTeamSync'
# The cert's own subject CN - used to find it after import without hardcoding a thumbprint here
# (the thumbprint is already embedded in Sync-OneDriveTeams.ps1 itself, which CI regenerates).
$CertSubject = 'CN=OneDrive-TeamSync-App'


function Remove-LegacyOneDriveSyncSetup
{
    # The tool this replaces: a per-user Startup shortcut plus a script it dropped in C:\Scripts.
    # Its own remediation was already disabled tenant-side, but any device that picked it up
    # before that still has these lying around with nothing left to clean them up.
    Write-ADTLogEntry -Message "Removing legacy OneDrive Sync Setup artifacts (if present)."

    Remove-Item -LiteralPath 'C:\Scripts\odsetup.ps1' -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath 'C:\ProgramData\Microsoft\Windows\Start Menu\Programs\Startup\ODSync.lnk' -Force -ErrorAction SilentlyContinue

    Get-ChildItem -Path 'C:\Users' -Directory -ErrorAction SilentlyContinue | ForEach-Object {
        $userStartup = Join-Path $_.FullName 'AppData\Roaming\Microsoft\Windows\Start Menu\Programs\Startup\ODSync.lnk'
        Remove-Item -LiteralPath $userStartup -Force -ErrorAction SilentlyContinue
    }
}

function Install-TeamSyncCertificate
{
    param([Parameter(Mandatory)][string]$PfxPath, [Parameter(Mandatory)][string]$PfxPassword)

    # The sync script runs as SYSTEM (the AutoMountTeamSites registry path it needs to write is
    # writable only by SYSTEM/Administrators, confirmed via a real ACL check - not even the user
    # it acts on behalf of can write it), so LocalMachine\My's default SYSTEM/Administrators-only
    # access is exactly right here - no ACL broadening needed, unlike an earlier version of this
    # script that ran as the interactive user and had to grant Authenticated Users read access.
    $securePw = ConvertTo-SecureString -String $PfxPassword -Force -AsPlainText
    $cert = Import-PfxCertificate -FilePath $PfxPath -CertStoreLocation 'Cert:\LocalMachine\My' -Password $securePw -Exportable:$false
    return $cert.Thumbprint
}

function Register-ToastProtocolHandler
{
    # Registered machine-wide (any user) so a toast notification's Yes/No buttons can call back
    # into the sync script, since a script-hosted toast has no native activation callback of its
    # own outside a full packaged app.
    $classesPath = 'HKLM:\SOFTWARE\Classes\odteamsync'
    New-Item -Path $classesPath -Force | Out-Null
    Set-ItemProperty -Path $classesPath -Name '(Default)' -Value 'URL:OneDrive Team Sync Protocol'
    New-ItemProperty -Path $classesPath -Name 'URL Protocol' -Value '' -PropertyType String -Force | Out-Null

    $commandPath = "$classesPath\shell\open\command"
    New-Item -Path $commandPath -Force | Out-Null
    $callbackCommand = "powershell.exe -WindowStyle Hidden -ExecutionPolicy Bypass -NonInteractive -File `"$ScriptDest`" -ToastCallback `"%1`""
    Set-ItemProperty -Path $commandPath -Name '(Default)' -Value $callbackCommand
}

function Register-LogonTask
{
    # Built and registered via schtasks.exe /create /xml rather than the ScheduledTasks module -
    # Register-ScheduledTask with a GroupId principal silently failed to persist the task on a
    # non-English (Swedish) system with no error surfaced at all (install completed, exit 0, no
    # task). The XML form's own registration path has proven more reliable than the newer
    # PowerShell cmdlets for this scenario generally, independent of that specific bug.
    #
    # Runs as SYSTEM (S-1-5-18), not as the logged-on user: the AutoMountTeamSites registry path
    # the sync script writes to is writable only by SYSTEM/Administrators, confirmed via a real
    # ACL check - not even the user it acts on behalf of can write it. The script itself resolves
    # the actual interactive user (via explorer.exe's owning SID) and operates on their
    # HKEY_USERS hive explicitly rather than relying on HKCU, which under SYSTEM would just be
    # SYSTEM's own (irrelevant) profile.
    $xml = @"
<?xml version="1.0" encoding="UTF-16"?>
<Task version="1.2" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
  <Triggers>
    <LogonTrigger>
      <Enabled>true</Enabled>
    </LogonTrigger>
  </Triggers>
  <Principals>
    <Principal id="Author">
      <UserId>S-1-5-18</UserId>
      <RunLevel>HighestAvailable</RunLevel>
    </Principal>
  </Principals>
  <Settings>
    <MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy>
    <DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries>
    <StopIfGoingOnBatteries>false</StopIfGoingOnBatteries>
    <Hidden>true</Hidden>
    <ExecutionTimeLimit>PT45M</ExecutionTimeLimit>
  </Settings>
  <Actions Context="Author">
    <Exec>
      <Command>powershell.exe</Command>
      <Arguments>-WindowStyle Hidden -ExecutionPolicy Bypass -NonInteractive -File "$ScriptDest"</Arguments>
    </Exec>
  </Actions>
</Task>
"@
    $xmlPath = Join-Path $env:TEMP 'OneDriveTeamSync-task.xml'
    # schtasks.exe requires the XML file itself to be UTF-16 - plain Out-File defaults to UTF-8.
    [System.IO.File]::WriteAllText($xmlPath, $xml, [System.Text.Encoding]::Unicode)

    # schtasks.exe writes its "task not found" message to stderr on a delete-before-create -
    # completely expected/harmless on first install, but under $ErrorActionPreference = 'Stop'
    # (set globally below), merging that stderr line into the pipeline via 2>&1 gets promoted
    # to a terminating NativeCommandError and aborted the whole install (confirmed via a real
    # failed install on LF52389). Run both calls under a locally-relaxed preference instead,
    # and rely on $LASTEXITCODE for the actual success/failure check.
    $previousEap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try
    {
        schtasks.exe /Delete /TN $TaskName /F 2>$null | Out-Null
        $result = schtasks.exe /Create /TN $TaskName /XML $xmlPath /F 2>&1
        if ($LASTEXITCODE -ne 0)
        {
            throw "schtasks.exe failed to register the '$TaskName' task: $result"
        }
    }
    finally
    {
        $ErrorActionPreference = $previousEap
    }
    Remove-Item -LiteralPath $xmlPath -Force -ErrorAction SilentlyContinue
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

    Remove-LegacyOneDriveSyncSetup


    ##================================================
    ## MARK: Install
    ##================================================
    $adtSession.InstallPhase = $adtSession.DeploymentType

    New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null
    Copy-Item -Path (Join-Path $adtSession.DirSupportFiles 'Sync-OneDriveTeams.ps1') -Destination $ScriptDest -Force

    $pfxPath = Join-Path $adtSession.DirSupportFiles 'onedrive-teamsync-cert.pfx'
    $pfxPasswordPath = Join-Path $adtSession.DirSupportFiles 'onedrive-teamsync-cert.pfx.pw'
    $pfxPassword = Get-Content -LiteralPath $pfxPasswordPath -Raw

    # Skip re-importing if this exact cert is already present (Import-PfxCertificate isn't
    # idempotent-cheap, and repeat installs during testing shouldn't keep duplicating it).
    $existing = Get-ChildItem 'Cert:\LocalMachine\My' | Where-Object { $_.Subject -eq $CertSubject }
    if (-not $existing)
    {
        $thumbprint = Install-TeamSyncCertificate -PfxPath $pfxPath -PfxPassword $pfxPassword
        Write-ADTLogEntry -Message "Certificate imported: $thumbprint"
    }
    else
    {
        Write-ADTLogEntry -Message "Certificate already present: $($existing[0].Thumbprint)"
    }

    # The PFX and its password only ever exist transiently on disk during this install step -
    # delete them immediately after use, same pattern as device-inventory-report's client cert.
    Remove-Item -LiteralPath $pfxPath -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $pfxPasswordPath -Force -ErrorAction SilentlyContinue

    Register-ToastProtocolHandler
    Register-LogonTask


    ##================================================
    ## MARK: Post-Install
    ##================================================
    $adtSession.InstallPhase = "Post-$($adtSession.DeploymentType)"

    if (-not (Test-Path -LiteralPath $CertThumbprintRegKey))
    {
        New-Item -Path $CertThumbprintRegKey -Force | Out-Null
    }
    Set-ItemProperty -LiteralPath $CertThumbprintRegKey -Name 'Version' -Value $adtSession.AppVersion -Type String
    Write-ADTLogEntry -Message "OneDrive Team Sync install completed."
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

    schtasks.exe /Delete /TN $TaskName /F 2>$null | Out-Null
    Remove-Item -Path 'HKLM:\SOFTWARE\Classes\odteamsync' -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -Path $InstallDir -Recurse -Force -ErrorAction SilentlyContinue
    Get-ChildItem 'Cert:\LocalMachine\My' | Where-Object { $_.Subject -eq $CertSubject } | Remove-Item -Force -ErrorAction SilentlyContinue


    ##================================================
    ## MARK: Post-Uninstallation
    ##================================================
    $adtSession.InstallPhase = "Post-$($adtSession.DeploymentType)"

    if (Test-Path -LiteralPath $CertThumbprintRegKey)
    {
        Remove-ADTRegistryKey -Key $CertThumbprintRegKey -Recurse
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
    Register-LogonTask
}


##================================================
## MARK: Initialization
##================================================

$ErrorActionPreference = [System.Management.Automation.ActionPreference]::Stop
$ProgressPreference = [System.Management.Automation.ActionPreference]::SilentlyContinue
Set-StrictMode -Version 1

try
{
    if (Test-Path -LiteralPath "$PSScriptRoot\PSAppDeployToolkit\PSAppDeployToolkit.psd1" -PathType Leaf)
    {
        Get-ChildItem -LiteralPath "$PSScriptRoot\PSAppDeployToolkit" -Recurse -File | Unblock-File -ErrorAction Ignore
        Import-Module -FullyQualifiedName @{ ModuleName = "$PSScriptRoot\PSAppDeployToolkit\PSAppDeployToolkit.psd1"; Guid = '8c3c366b-8606-4576-9f2d-4051144f7ca2'; ModuleVersion = '4.1.8' } -Force
    }
    else
    {
        Import-Module -FullyQualifiedName @{ ModuleName = 'PSAppDeployToolkit'; Guid = '8c3c366b-8606-4576-9f2d-4051144f7ca2'; ModuleVersion = '4.1.8' } -Force
    }

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

try
{
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

    & "$($adtSession.DeploymentType)-ADTDeployment"
    Close-ADTSession
}
catch
{
    $mainErrorMessage = "An unhandled error within [$($MyInvocation.MyCommand.Name)] has occurred.`n$(Resolve-ADTErrorRecord -ErrorRecord $_)"
    Write-ADTLogEntry -Message $mainErrorMessage -Severity 3
    Close-ADTSession -ExitCode 60001
}
