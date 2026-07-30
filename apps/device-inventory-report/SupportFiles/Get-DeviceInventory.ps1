#Requires -Version 5.1
<#
.SYNOPSIS
    Collects hardware details Intune/Graph does not expose (CPU model, GPU, physical
    disk model/type) and reports them to the Dashhouse Admin UI's ingest endpoint.

.DESCRIPTION
    Runs as NT AUTHORITY\SYSTEM from a scheduled task on a daily trigger. Everything
    else about a device (RAM, disk capacity, TPM, BitLocker, signed-in users, ...) is
    already pulled centrally via Microsoft Graph by Dashhouse's own sync job - this
    script exists only to fill the one real gap: Microsoft Graph has no field for CPU
    model name on Intune-managed Windows devices.

    Identifies the device by its Entra ID (Azure AD) device ID, read from
    `dsregcmd /status` - the same identifier Dashhouse's Intune sync already joins
    sign-in data on (`azure_ad_device_id`), so no new correlation key is introduced.

    Posts a small JSON payload to the ingest endpoint over HTTPS, authenticated with a
    shared secret header. The endpoint upserts by device ID, so re-running (or a
    hardware change) simply replaces the prior report - no history is kept, since none
    is needed for hardware that changes rarely.

.NOTES
    Deployed to disk by the PSADT Win32 app; invoked by the "Dashhouse - Device
    Inventory Report" scheduled task. Not intended to be run manually as a normal user,
    though running it interactively for testing is harmless (it only reads hardware
    info and posts a report).
#>
[CmdletBinding()]
param (
    [String]$ConfigPath,
    [String]$LogPath = (Join-Path $env:ProgramData 'Organization\DeviceInventory\Logs\Get-DeviceInventory.log')
)

if ([string]::IsNullOrWhiteSpace($ConfigPath)) { $ConfigPath = Join-Path $PSScriptRoot 'DeviceInventoryConfig.json' }

$ErrorActionPreference = 'Stop'

function Write-InventoryLog {
    <#
    .SYNOPSIS
        Appends one line to the run's log file, rotating it if it has grown past 2MB.
        Never throws - logging must not be able to break the run.
    .PARAMETER Message
        The text to log.
    .PARAMETER Severity
        Info (default), Warning, or Error.
    .OUTPUTS
        None.
    #>
    param(
        [Parameter(Mandatory)][String]$Message,
        [ValidateSet('Info', 'Warning', 'Error')][String]$Severity = 'Info'
    )
    try {
        $logDir = Split-Path -Path $LogPath -Parent
        if (-not (Test-Path -LiteralPath $logDir)) {
            New-Item -Path $logDir -ItemType Directory -Force | Out-Null
        }
        if ((Test-Path -LiteralPath $LogPath) -and ((Get-Item -LiteralPath $LogPath).Length -gt 2MB)) {
            Remove-Item -LiteralPath $LogPath -Force -ErrorAction SilentlyContinue
        }
        $line = '[{0}] [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Severity, $Message
        Add-Content -LiteralPath $LogPath -Value $line -Encoding UTF8
    } catch {
        # Logging must never break the run.
    }
}

function Get-AzureAdDeviceId {
    <#
    .SYNOPSIS
        Reads this device's Entra ID (Azure AD) device GUID from `dsregcmd /status`.
        This is the same identifier Dashhouse's central Intune sync already stores as
        `azure_ad_device_id`, so reports from this script join onto existing device
        rows without needing a new lookup.
    .OUTPUTS
        [String] the device GUID, or $null if the device isn't Azure AD joined or the
        output could not be parsed.
    #>
    try {
        $status = & dsregcmd /status 2>$null
    } catch {
        Write-InventoryLog -Severity Error -Message "dsregcmd /status failed to run: $_"
        return $null
    }
    $line = $status | Select-String -Pattern '^\s*DeviceId\s*:\s*(\S+)' | Select-Object -First 1
    if (-not $line) {
        Write-InventoryLog -Severity Warning -Message 'Could not find DeviceId in dsregcmd /status output - device may not be Azure AD joined.'
        return $null
    }
    return $line.Matches[0].Groups[1].Value
}

function Get-CpuInventory {
    <#
    .SYNOPSIS
        Reads the primary CPU's model name and core/thread counts.
    .OUTPUTS
        [pscustomobject] { Model; Cores; LogicalProcessors } - fields are $null if the
        query failed.
    #>
    try {
        $cpu = Get-CimInstance -ClassName Win32_Processor -ErrorAction Stop | Select-Object -First 1
        return [pscustomobject]@{
            Model             = if ($cpu.Name) { $cpu.Name.Trim() } else { $null }
            Cores             = $cpu.NumberOfCores
            LogicalProcessors = $cpu.NumberOfLogicalProcessors
        }
    } catch {
        Write-InventoryLog -Severity Warning -Message "Get-CimInstance Win32_Processor failed: $_"
        return [pscustomobject]@{ Model = $null; Cores = $null; LogicalProcessors = $null }
    }
}

function Get-GpuInventory {
    <#
    .SYNOPSIS
        Reads every video controller's name (a device can have more than one, e.g. an
        integrated + discrete GPU) and joins them into one string.
    .OUTPUTS
        [String] comma-separated GPU model names, or $null if none were found/readable.
    #>
    try {
        $names = @(Get-CimInstance -ClassName Win32_VideoController -ErrorAction Stop |
            Where-Object { $_.Name } | Select-Object -ExpandProperty Name)
        if ($names.Count -eq 0) { return $null }
        return ($names -join ', ')
    } catch {
        Write-InventoryLog -Severity Warning -Message "Get-CimInstance Win32_VideoController failed: $_"
        return $null
    }
}

function Get-PrimaryDiskInventory {
    <#
    .SYNOPSIS
        Reads the model and media type (SSD/HDD/Unspecified) of the system's primary
        physical disk - the one holding the Windows partition. Falls back to the first
        disk reported if the OS disk can't be identified directly.
    .OUTPUTS
        [pscustomobject] { Model; MediaType } - fields are $null if the query failed.
    #>
    try {
        $osDiskNumber = (Get-CimInstance -ClassName Win32_DiskPartition -ErrorAction Stop |
            Where-Object { (Get-CimAssociatedInstance -InputObject $_ -ResultClassName Win32_LogicalDisk -ErrorAction SilentlyContinue).DeviceID -eq $env:SystemDrive } |
            Select-Object -First 1 -ExpandProperty DiskIndex)

        $disks = @(Get-PhysicalDisk -ErrorAction Stop)
        $disk = $null
        if ($null -ne $osDiskNumber) {
            $disk = $disks | Where-Object { $_.DeviceId -eq [string]$osDiskNumber } | Select-Object -First 1
        }
        if (-not $disk) { $disk = $disks | Select-Object -First 1 }

        if (-not $disk) { return [pscustomobject]@{ Model = $null; MediaType = $null } }
        return [pscustomobject]@{
            Model     = if ($disk.FriendlyName) { $disk.FriendlyName.Trim() } else { $null }
            MediaType = [string]$disk.MediaType
        }
    } catch {
        Write-InventoryLog -Severity Warning -Message "Physical disk lookup failed: $_"
        return [pscustomobject]@{ Model = $null; MediaType = $null }
    }
}

function Read-InventoryConfigFile {
    <#
    .SYNOPSIS
        Reads and parses the JSON config file (ingest URL + shared secret).
    .PARAMETER Path
        Full path to the JSON config file.
    .OUTPUTS
        The parsed JSON object, or $null on failure.
    #>
    param([Parameter(Mandatory)][String]$Path)
    if (-not (Test-Path -LiteralPath $Path)) {
        Write-InventoryLog -Severity Error -Message "Config file not found at '$Path'."
        return $null
    }
    try {
        return Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json
    } catch {
        Write-InventoryLog -Severity Error -Message "Failed to parse config file '$Path': $_"
        return $null
    }
}

#region Main
Write-InventoryLog -Message 'Starting device inventory collection.'

$config = Read-InventoryConfigFile -Path $ConfigPath
if (-not $config -or -not $config.IngestUrl -or -not $config.IngestKey) {
    Write-InventoryLog -Severity Error -Message 'Missing IngestUrl/IngestKey in config - aborting.'
    exit 1
}

$azureAdDeviceId = Get-AzureAdDeviceId
if (-not $azureAdDeviceId) {
    Write-InventoryLog -Severity Error -Message 'Could not determine this device''s Azure AD device ID - aborting (nothing to correlate the report with).'
    exit 1
}

$cpu = Get-CpuInventory
$gpuModel = Get-GpuInventory
$disk = Get-PrimaryDiskInventory

$payload = @{
    azureAdDeviceId       = $azureAdDeviceId
    deviceName             = $env:COMPUTERNAME
    cpuModel               = $cpu.Model
    cpuCores               = $cpu.Cores
    cpuLogicalProcessors   = $cpu.LogicalProcessors
    gpuModel               = $gpuModel
    diskModel               = $disk.Model
    diskMediaType           = $disk.MediaType
    collectedAtUtc          = (Get-Date).ToUniversalTime().ToString('o')
} | ConvertTo-Json -Compress

Write-InventoryLog -Message "Collected: CPU='$($cpu.Model)' ($($cpu.Cores)c/$($cpu.LogicalProcessors)t), GPU='$gpuModel', Disk='$($disk.Model)' ($($disk.MediaType))."

try {
    $response = Invoke-RestMethod -Method Post -Uri $config.IngestUrl -Body $payload -ContentType 'application/json' `
        -Headers @{ 'X-Ingest-Key' = $config.IngestKey } -TimeoutSec 30
    Write-InventoryLog -Message "Report sent successfully for device ID '$azureAdDeviceId'. Response: $($response | ConvertTo-Json -Compress)"
} catch {
    Write-InventoryLog -Severity Error -Message "Failed to send report: $_"
    exit 1
}
#endregion
