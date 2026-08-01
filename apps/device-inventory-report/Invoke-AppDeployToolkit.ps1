<#

.SYNOPSIS
PSAppDeployToolkit - This script performs the installation or uninstallation of an application(s).

.DESCRIPTION
- The script is provided as a template to perform an install, uninstall, or repair of an application(s).
- The script either performs an "Install", "Uninstall", or "Repair" deployment type.
- The install deployment type is broken down into 3 main sections/phases: Pre-Install, Install, and Post-Install.

The script imports the PSAppDeployToolkit module which contains the logic and functions required to install or uninstall an application.

This deployment is a background reporting framework rather than a traditional
application install: it deploys a worker script and a daily scheduled task that
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
    AppVersion = '3.3.0'
    AppArch = ''
    AppLang = 'EN'
    AppRevision = '01'
    AppSuccessExitCodes = @(0)
    AppRebootExitCodes = @(1641, 3010)
    AppProcessesToClose = @()
    AppScriptVersion = '3.3.0'
    AppScriptDate = '2026-08-01'
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
$DeviceInventoryBenchmarkScriptFileName = 'Invoke-CpuBenchmark.ps1'
$DeviceInventoryBenchmarkTaskName = 'Organization - CPU Benchmark'
$DeviceInventoryBenchmarkForcedTaskName = 'Organization - CPU Benchmark (Weekly Forced)'


function Register-DeviceInventoryScheduledTask
{
    <#
        Daily (04:30 local time, up to 1h random delay so a whole fleet doesn't hit
        the ingest endpoint at once). Hardware identity (CPU/GPU/disk model) changes
        rarely, so most fields won't move day to day - but location, network
        attachment point, TPM/BitLocker/Defender state, and local admin membership
        can all shift meaningfully within days, and this data is exactly what you'd
        want on hand *after* a device goes missing. A weekly cadence means up to six
        days of blind spot between a device's last-known-good report and it going
        dark - daily bounds that gap to under a day, which matters far more here than
        the wasted-request cost of re-collecting mostly-unchanged hardware facts.

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
    $trigger   = New-ScheduledTaskTrigger -Daily -At '04:30'
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

    Write-ADTLogEntry -Message "Scheduled task '$DeviceInventoryTaskName' registered and verified (runs as SYSTEM, daily 04:30 + up to 1h random delay)."
}

function Register-CpuBenchmarkIdleScheduledTask
{
    <#
        Idle-triggered rather than time-triggered: Task Scheduler itself gates this
        on the device being idle (-RunOnlyIfIdle), which is the correct way to
        detect idle from a task running as SYSTEM. GetLastInputInfo() and similar
        APIs, called from a SYSTEM process in session 0, cannot see the interactive
        user's session input at all - a hand-rolled idle check from inside the
        worker script would silently be wrong. Task Scheduler's own idle engine has
        no such blind spot.

        The daily trigger time below is only when Task Scheduler starts *waiting*
        for idle, not when the benchmark runs - IdleWaitTimeout gives it up to 20
        hours from that point to catch an idle window before giving up until the
        next day's trigger. Deliberately NOT started immediately at install time
        (unlike the inventory task above) - forcing it to run during an Intune push
        would defeat the entire point of waiting for idle.

        120 seconds per phase (see -DurationSeconds below): short fixed-work runs
        mostly measure L1/L2 cache bandwidth and CPU boost-clock behavior rather
        than sustained throughput, so this is deliberately long enough to run past
        both. This is the accurate, primary reading - see
        Register-CpuBenchmarkForcedScheduledTask for the shorter weekly fallback
        that covers devices this idle trigger rarely catches.
    #>
    $powershellExe = Join-Path $env:WinDir 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $scriptPath    = Join-Path $DeviceInventoryInstallDir $DeviceInventoryBenchmarkScriptFileName
    $configPath    = Join-Path $DeviceInventoryInstallDir $DeviceInventoryConfigFileName
    $arguments     = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$scriptPath`" -ConfigPath `"$configPath`" -DurationSeconds 120"

    $action    = New-ScheduledTaskAction -Execute $powershellExe -Argument $arguments
    $trigger   = New-ScheduledTaskTrigger -Daily -At '10:00'
    $principal = New-ScheduledTaskPrincipal -UserId 'S-1-5-18' -LogonType ServiceAccount -RunLevel Highest
    $settings  = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
                    -Hidden -StartWhenAvailable -MultipleInstances IgnoreNew `
                    -ExecutionTimeLimit (New-TimeSpan -Minutes 10) `
                    -RunOnlyIfIdle -IdleDuration (New-TimeSpan -Minutes 10) -IdleWaitTimeout (New-TimeSpan -Hours 20)

    if (Get-ScheduledTask -TaskName $DeviceInventoryBenchmarkTaskName -ErrorAction SilentlyContinue)
    {
        Write-ADTLogEntry -Message "Scheduled task '$DeviceInventoryBenchmarkTaskName' already exists; replacing it."
        Unregister-ScheduledTask -TaskName $DeviceInventoryBenchmarkTaskName -Confirm:$false
    }

    Register-ScheduledTask -TaskName $DeviceInventoryBenchmarkTaskName -Action $action -Trigger $trigger `
        -Principal $principal -Settings $settings `
        -Description 'Runs a 120s/phase CPU throughput benchmark once the device has been idle for a while and reports the result to Dashhouse. Deployed by Organization IT.' | Out-Null

    # Same reasoning as the inventory task's post-registration check: fail the
    # install visibly rather than silently leave nothing scheduled.
    if (-not (Get-ScheduledTask -TaskName $DeviceInventoryBenchmarkTaskName -ErrorAction SilentlyContinue))
    {
        throw "Scheduled task '$DeviceInventoryBenchmarkTaskName' was not present after registration."
    }

    Write-ADTLogEntry -Message "Scheduled task '$DeviceInventoryBenchmarkTaskName' registered and verified (idle-triggered, 120s/phase, daily wait window starting 10:00)."
}

function Register-CpuBenchmarkForcedScheduledTask
{
    <#
        Weekly fallback for the idle-gated benchmark above: runs regardless of idle
        state, so a device that's rarely or never idle still gets at least one
        throughput reading. The ingest endpoint keeps only the highest score ever
        reported per device (server-side MAX ratchet - see /api/inventory/benchmark),
        so a run that happens to compete with someone actively using the machine can
        only score the same or lower than a genuinely idle run: it can never corrupt
        a good reading, only fail to beat it. Over enough weekly samples this
        converges toward the same number the idle trigger would have found, for
        devices the idle trigger alone can't reach.

        Deliberately shorter than the idle task (30s/phase vs. 120s/phase) since this
        one may run while someone is actively working - minimizing how long it can
        visibly slow the device down matters more here than measurement precision,
        which the idle-gated task above already covers.

        Monday 13:00 was chosen deliberately: the start of a regular
        organization-wide short meeting, when most workstations are logged in and
        running but very few people are actively working at their computer (laptops
        carried to the meeting won't be present, but that's fine - they're more
        likely to satisfy the idle-gated task's own trigger on their own).

        RandomDelay serves two purposes: it spreads the fleet's near-simultaneous
        13:00 trigger over a window instead of every device posting to the ingest
        endpoint in the same second, and it is what keeps a *missed* trigger (device
        was off/asleep at 13:00 Monday, so StartWhenAvailable's catch-up fires this
        at next boot instead) from launching straight into a fresh boot's startup
        storm - the delay applies to a catch-up fire the same as a scheduled one.
    #>
    $powershellExe = Join-Path $env:WinDir 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $scriptPath    = Join-Path $DeviceInventoryInstallDir $DeviceInventoryBenchmarkScriptFileName
    $configPath    = Join-Path $DeviceInventoryInstallDir $DeviceInventoryConfigFileName
    $arguments     = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$scriptPath`" -ConfigPath `"$configPath`" -DurationSeconds 30"

    $action    = New-ScheduledTaskAction -Execute $powershellExe -Argument $arguments
    $trigger   = New-ScheduledTaskTrigger -Weekly -DaysOfWeek Monday -At '13:00'
    $trigger.RandomDelay = 'PT15M'
    $principal = New-ScheduledTaskPrincipal -UserId 'S-1-5-18' -LogonType ServiceAccount -RunLevel Highest
    $settings  = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
                    -Hidden -StartWhenAvailable -MultipleInstances IgnoreNew `
                    -ExecutionTimeLimit (New-TimeSpan -Minutes 5)

    if (Get-ScheduledTask -TaskName $DeviceInventoryBenchmarkForcedTaskName -ErrorAction SilentlyContinue)
    {
        Write-ADTLogEntry -Message "Scheduled task '$DeviceInventoryBenchmarkForcedTaskName' already exists; replacing it."
        Unregister-ScheduledTask -TaskName $DeviceInventoryBenchmarkForcedTaskName -Confirm:$false
    }

    Register-ScheduledTask -TaskName $DeviceInventoryBenchmarkForcedTaskName -Action $action -Trigger $trigger `
        -Principal $principal -Settings $settings `
        -Description 'Weekly fallback CPU throughput benchmark (30s/phase, not idle-gated) for devices the idle-triggered benchmark rarely catches. Deployed by Organization IT.' | Out-Null

    if (-not (Get-ScheduledTask -TaskName $DeviceInventoryBenchmarkForcedTaskName -ErrorAction SilentlyContinue))
    {
        throw "Scheduled task '$DeviceInventoryBenchmarkForcedTaskName' was not present after registration."
    }

    Write-ADTLogEntry -Message "Scheduled task '$DeviceInventoryBenchmarkForcedTaskName' registered and verified (weekly Monday 13:00 + up to 15min random delay, 30s/phase, not idle-gated)."
}

function Install-IngestClientCertificate
{
    <#
        Imports the ingest mutual-TLS client certificate into the local machine
        certificate store. The .pfx/.pfx.pw files only exist in SupportFiles when
        this package was built by CI (injected from repo secrets at build time - see
        build-and-publish.yml and this app's README's "Ingest authentication"
        section). They are deliberately absent from the source repo itself, so a
        local test build assembled by hand (rather than by CI) will not have them -
        that's expected, not an error; this function logs and returns rather than
        throwing, so a local install/uninstall test of everything else still works.

        Both files are deleted after import regardless of outcome, since there's no
        reason for the plaintext password file to persist on disk once the private
        key has been imported into the certificate store.
    #>
    $pfxPath = Join-Path $adtSession.DirSupportFiles 'client-cert.pfx'
    $pwPath = Join-Path $adtSession.DirSupportFiles 'client-cert.pfx.pw'

    if (-not (Test-Path -LiteralPath $pfxPath) -or -not (Test-Path -LiteralPath $pwPath))
    {
        Write-ADTLogEntry -Message 'Ingest client certificate not present in this package (expected for a locally-assembled test build - CI injects it from repo secrets). Skipping certificate import.' -Severity 2
        return
    }

    try
    {
        $password = (Get-Content -LiteralPath $pwPath -Raw -Encoding UTF8).Trim()
        $securePassword = ConvertTo-SecureString -String $password -AsPlainText -Force
        Import-PfxCertificate -FilePath $pfxPath -CertStoreLocation 'Cert:\LocalMachine\My' -Password $securePassword -Exportable:$false | Out-Null
        Write-ADTLogEntry -Message 'Ingest client certificate imported into Cert:\LocalMachine\My.'
    }
    catch
    {
        Write-ADTLogEntry -Message "Failed to import ingest client certificate: $_" -Severity 3
        throw
    }
    finally
    {
        Remove-Item -LiteralPath $pfxPath -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $pwPath -Force -ErrorAction SilentlyContinue
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
    Copy-ADTFile -Path "$($adtSession.DirSupportFiles)\$DeviceInventoryBenchmarkScriptFileName" -Destination $DeviceInventoryInstallDir
    Copy-ADTFile -Path "$($adtSession.DirSupportFiles)\$DeviceInventoryConfigFileName" -Destination $DeviceInventoryInstallDir


    ##================================================
    ## MARK: Post-Install
    ##================================================
    $adtSession.InstallPhase = "Post-$($adtSession.DeploymentType)"

    Install-IngestClientCertificate
    Register-DeviceInventoryScheduledTask
    Register-CpuBenchmarkIdleScheduledTask
    Register-CpuBenchmarkForcedScheduledTask
    Set-ADTRegistryKey -Key $DeviceInventoryRegKey -Name 'Version' -Value $adtSession.AppVersion -Type String

    # Run the inventory task once immediately so a newly enrolled or newly updated
    # device reports in right away rather than waiting up to a day for the next
    # scheduled run. The benchmark task is deliberately NOT started here - it waits
    # for its own idle-gated trigger; forcing it to run during an Intune push would
    # defeat the entire point.
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

    foreach ($taskName in @($DeviceInventoryTaskName, $DeviceInventoryBenchmarkTaskName, $DeviceInventoryBenchmarkForcedTaskName))
    {
        if (Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue)
        {
            Write-ADTLogEntry -Message "Removing scheduled task '$taskName'."
            Unregister-ScheduledTask -TaskName $taskName -Confirm:$false
        }
    }

    Get-ChildItem -Path 'Cert:\LocalMachine\My' -ErrorAction SilentlyContinue |
        Where-Object { $_.Subject -eq 'CN=dashhouse-device-ingest-client' } |
        ForEach-Object {
            Write-ADTLogEntry -Message "Removing ingest client certificate (thumbprint $($_.Thumbprint))."
            Remove-Item -LiteralPath $_.PSPath -Force -ErrorAction SilentlyContinue
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
