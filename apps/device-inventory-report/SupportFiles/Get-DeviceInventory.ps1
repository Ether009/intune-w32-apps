#Requires -Version 5.1
<#
.SYNOPSIS
    Collects a comprehensive hardware/security/health snapshot that Intune/Graph does
    not expose for Intune-managed Windows devices, and reports it to the Dashhouse
    Admin UI's ingest endpoint: TPM capabilities, firmware/boot mode, network adapters
    (including currently-connected SSID), identifying serials for the system's major
    components, local administrator membership, Defender status, pending-reboot and
    activation state, battery wear, disk SMART/reliability data, and connected
    monitors.

.DESCRIPTION
    Runs as NT AUTHORITY\SYSTEM from a scheduled task on a daily trigger. Everything
    Microsoft Graph *can* expose about a device (RAM, disk capacity, TPM version,
    BitLocker status, signed-in users, ...) is already pulled centrally by Dashhouse's
    own Intune sync job - this script exists only for what that job structurally
    cannot get.

    Identifies the device by its Entra ID (Azure AD) device ID, read from
    `dsregcmd /status` - the same identifier Dashhouse's Intune sync already joins
    sign-in data on (`azure_ad_device_id`), so no new correlation key is introduced.

    Posts a JSON payload (plus a nested array of network adapters) to the Dashhouse
    Admin UI's ingest endpoint, authenticated with a shared secret header. The
    endpoint upserts by device ID - re-running (or a hardware change) simply replaces
    the prior report, and the adapter list is fully replaced each run rather than
    diffed, since adapters can appear/disappear (USB dongles, docking stations).

.NOTES
    What "attestation ready" means here: `tpmReadyForAttestation` /
    `tpmCapableForAttestation` come straight from `tpmtool.exe GetDeviceInformation`'s
    own "Ready For Attestation" / "Is Capable For Attestation" fields - this is
    Microsoft's own local determination (it accounts for EK certificate validity,
    PCR bank state, etc.), not a heuristic assembled here from raw TPM properties.
    It's still a local, offline check rather than a live round-trip to Microsoft's
    Device Directory Service, so on rare edge cases it can disagree with what an
    actual Autopilot enrollment attempt reports - but it is the same authoritative
    computation Windows itself uses, not a guess. A virtual TPM (Hyper-V, VMware,
    cloud VMs) genuinely fails this check (reports not capable/not ready), which is
    why it correctly flags VMs as unfit for self-deploying/white-glove Autopilot.

    Deployed to disk by the PSADT Win32 app; invoked by the "Dashhouse - Device
    Inventory Report" scheduled task. Not intended to be run manually as a normal
    user, though running it interactively for testing is harmless (it only reads
    hardware info and posts a report).
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
        Same identifier Dashhouse's central Intune sync stores as
        `azure_ad_device_id`, so reports from this script join onto existing device
        rows without a new lookup.
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
        Reads the primary CPU's model name, core/thread counts, and ProcessorId - the
        closest thing to a CPU "serial" Windows exposes (real per-chip serial numbers
        were dropped from x86 CPUs after the Pentium III era for privacy reasons).
    .OUTPUTS
        [pscustomobject] { Model; Cores; LogicalProcessors; ProcessorId } - fields are
        $null if the query failed.
    #>
    try {
        $cpu = Get-CimInstance -ClassName Win32_Processor -ErrorAction Stop | Select-Object -First 1
        return [pscustomobject]@{
            Model             = if ($cpu.Name) { $cpu.Name.Trim() } else { $null }
            Cores             = $cpu.NumberOfCores
            LogicalProcessors = $cpu.NumberOfLogicalProcessors
            ProcessorId       = $cpu.ProcessorId
        }
    } catch {
        Write-InventoryLog -Severity Warning -Message "Get-CimInstance Win32_Processor failed: $_"
        return [pscustomobject]@{ Model = $null; Cores = $null; LogicalProcessors = $null; ProcessorId = $null }
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
        Reads the model, media type (SSD/HDD/Unspecified), serial number, health
        status, and SMART/reliability counters (wear, temperature, power-on hours,
        read/write error totals) of the system's primary physical disk - the one
        holding the Windows partition. Falls back to the first disk reported if the
        OS disk can't be identified directly.
    .OUTPUTS
        [pscustomobject] { Model; MediaType; Serial; HealthStatus; WearPercentage;
        TemperatureCelsius; PowerOnHours; ReadErrorsTotal; WriteErrorsTotal } - fields
        are $null if the underlying query failed or (for wear) isn't supported by
        this disk.
    #>
    $result = [pscustomobject]@{
        Model = $null; MediaType = $null; Serial = $null; HealthStatus = $null
        WearPercentage = $null; TemperatureCelsius = $null; PowerOnHours = $null
        ReadErrorsTotal = $null; WriteErrorsTotal = $null
    }
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
        if (-not $disk) { return $result }

        $result.Model = if ($disk.FriendlyName) { $disk.FriendlyName.Trim() } else { $null }
        $result.MediaType = [string]$disk.MediaType
        $result.Serial = if ($disk.SerialNumber) { $disk.SerialNumber.Trim() } else { $null }
        $result.HealthStatus = [string]$disk.HealthStatus

        try {
            # Requires admin - expected to succeed running as SYSTEM, fail in an
            # unelevated test shell (same pattern as the TPM/Secure Boot checks).
            $reliability = $disk | Get-StorageReliabilityCounter -ErrorAction Stop
            $result.WearPercentage = $reliability.Wear
            $result.TemperatureCelsius = $reliability.Temperature
            $result.PowerOnHours = $reliability.PowerOnHours
            $result.ReadErrorsTotal = $reliability.ReadErrorsTotal
            $result.WriteErrorsTotal = $reliability.WriteErrorsTotal
        } catch {
            Write-InventoryLog -Severity Warning -Message "Get-StorageReliabilityCounter failed (requires admin): $_"
        }
    } catch {
        Write-InventoryLog -Severity Warning -Message "Physical disk lookup failed: $_"
    }
    return $result
}

function Get-LocalAdministratorInventory {
    <#
    .SYNOPSIS
        Lists members of the local Administrators group. Uses the well-known SID
        (S-1-5-32-544) rather than the localized group name 'Administrators' - on a
        non-English Windows install (this fleet includes Swedish-locale devices) the
        group is actually named something else, and Get-LocalGroupMember -Group
        'Administrators' fails outright on those. Best-effort resolves Azure AD SIDs
        (PrincipalSource 'eAD') to a friendly UPN via the identity store cache; falls
        back to the raw SID when no cache entry exists (e.g. a group that was granted
        admin rights but has never itself signed in locally - a group SID has no
        interactive session to populate the cache with in the first place).
    .OUTPUTS
        [System.Collections.Generic.List[pscustomobject]] one entry per member:
        { Name; Sid; ObjectClass; IsLocalAccount }.
    #>
    $members = New-Object System.Collections.Generic.List[Object]
    try {
        $localAdmins = @(Get-LocalGroupMember -SID 'S-1-5-32-544' -ErrorAction Stop)
        foreach ($m in $localAdmins) {
            $name = $m.Name
            if ($m.PrincipalSource -eq 'MicrosoftAccount' -or $m.PrincipalSource -eq 'AzureAD') {
                $cachePath = "HKLM:\SOFTWARE\Microsoft\IdentityStore\Cache\$($m.SID)\IdentityCache"
                if (Test-Path -LiteralPath $cachePath) {
                    $cached = Get-ChildItem -LiteralPath $cachePath -ErrorAction SilentlyContinue | Select-Object -First 1
                    if ($cached) {
                        $upn = (Get-ItemProperty -LiteralPath $cached.PSPath -ErrorAction SilentlyContinue).UserName
                        if ($upn) { $name = $upn }
                    }
                }
            }
            $members.Add([pscustomobject]@{
                Name           = $name
                Sid            = [string]$m.SID
                ObjectClass    = [string]$m.ObjectClass
                IsLocalAccount = ($m.PrincipalSource -eq 'Local')
            })
        }
    } catch {
        Write-InventoryLog -Severity Warning -Message "Get-LocalGroupMember (Administrators) failed: $_"
    }
    return $members
}

function Get-DefenderInventory {
    <#
    .SYNOPSIS
        Reads Microsoft Defender's antivirus/real-time-protection state and signature
        age. Not available at all on a device running a third-party AV that disables
        Defender's engine entirely - that case is left as $null rather than reported
        as "protection off", since it isn't a Defender-specific fact in that case.
    .OUTPUTS
        [pscustomobject] { AntivirusEnabled; RealtimeProtectionEnabled;
        SignatureAgeDays; LastQuickScan; LastFullScan }
    #>
    $result = [pscustomobject]@{
        AntivirusEnabled = $null; RealtimeProtectionEnabled = $null
        SignatureAgeDays = $null; LastQuickScan = $null; LastFullScan = $null
    }
    try {
        $mp = Get-MpComputerStatus -ErrorAction Stop
        $result.AntivirusEnabled = [bool]$mp.AntivirusEnabled
        $result.RealtimeProtectionEnabled = [bool]$mp.RealTimeProtectionEnabled
        $result.SignatureAgeDays = $mp.AntivirusSignatureAge
        $result.LastQuickScan = if ($mp.QuickScanEndTime) { $mp.QuickScanEndTime.ToUniversalTime().ToString('o') } else { $null }
        $result.LastFullScan = if ($mp.FullScanEndTime) { $mp.FullScanEndTime.ToUniversalTime().ToString('o') } else { $null }
    } catch {
        Write-InventoryLog -Message "Get-MpComputerStatus failed (expected if a third-party AV has disabled the Defender engine): $_"
    }
    return $result
}

function Test-PendingReboot {
    <#
    .SYNOPSIS
        Checks the standard registry locations Windows/WSUS/CBS use to flag that a
        restart is required to finish applying an update.
    .OUTPUTS
        [bool] $true if any recognized pending-reboot marker is present.
    #>
    $markers = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending',
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired'
    )
    foreach ($path in $markers) {
        if (Test-Path -LiteralPath $path) { return $true }
    }
    return $false
}

function Get-WindowsActivationStatus {
    <#
    .SYNOPSIS
        Reads the Windows (not Office or any other product) activation status via
        SoftwareLicensingProduct, filtered to the Windows application ID so a device
        with an Office license installed doesn't return the wrong product's status.
    .OUTPUTS
        [String] a friendly status name (Licensed/Unlicensed/OutOfBoxGrace/etc.), or
        $null if it couldn't be determined.
    #>
    # https://learn.microsoft.com/windows/win32/wmi/win32-provider--slp-classes: 0-6.
    $statusNames = @{
        0 = 'Unlicensed'; 1 = 'Licensed'; 2 = 'OutOfBoxGrace'; 3 = 'OutOfToleranceGrace'
        4 = 'NonGenuineGrace'; 5 = 'Notification'; 6 = 'ExtendedGrace'
    }
    try {
        $product = Get-CimInstance -ClassName SoftwareLicensingProduct -ErrorAction Stop -Filter (
            "ApplicationID='55c92734-d682-4d71-983e-d6ec3f16059f' AND PartialProductKey IS NOT NULL"
        ) | Select-Object -First 1
        if (-not $product) { return $null }
        if ($statusNames.ContainsKey([int]$product.LicenseStatus)) { return $statusNames[[int]$product.LicenseStatus] }
        return "Unknown($($product.LicenseStatus))"
    } catch {
        Write-InventoryLog -Severity Warning -Message "Windows activation status lookup failed: $_"
        return $null
    }
}

function Get-BatteryInventory {
    <#
    .SYNOPSIS
        Reads battery design capacity, current full-charge capacity, and cycle count
        via `powercfg /batteryreport`, rather than the per-vendor WMI battery classes
        (BatteryStaticData/BatteryFullChargedCapacity/BatteryCycleCount) - those were
        found unreliable in practice (one returned "Generic failure", another
        returned nothing, on a real Surface device with a perfectly normal battery).
        powercfg is Microsoft's own official battery-health tool and reads the same
        underlying data far more consistently across manufacturers.

        Returns all-null (not an error) on a desktop with no battery - the XML report
        still generates but its Batteries section is empty, which is a normal outcome.
    .OUTPUTS
        [pscustomobject] { DesignCapacityMwh; FullChargeCapacityMwh; CycleCount }
    #>
    $result = [pscustomobject]@{ DesignCapacityMwh = $null; FullChargeCapacityMwh = $null; CycleCount = $null }
    $reportPath = Join-Path $env:TEMP "battery-report-$PID.xml"
    try {
        & powercfg /batteryreport /xml /output $reportPath 2>$null | Out-Null
        if (-not (Test-Path -LiteralPath $reportPath)) { return $result }
        [xml]$xml = Get-Content -LiteralPath $reportPath -Raw
        $battery = $xml.BatteryReport.Batteries.Battery | Select-Object -First 1
        if ($battery) {
            $result.DesignCapacityMwh = if ($battery.DesignCapacity) { [int64]$battery.DesignCapacity } else { $null }
            $result.FullChargeCapacityMwh = if ($battery.FullChargeCapacity) { [int64]$battery.FullChargeCapacity } else { $null }
            $result.CycleCount = if ($battery.CycleCount) { [int]$battery.CycleCount } else { $null }
        }
    } catch {
        Write-InventoryLog -Severity Warning -Message "Battery report lookup failed: $_"
    } finally {
        Remove-Item -LiteralPath $reportPath -Force -ErrorAction SilentlyContinue
    }
    return $result
}

function ConvertFrom-EdidBytes {
    <#
    .SYNOPSIS
        Converts a WmiMonitorID byte-array field (ManufacturerName/UserFriendlyName/
        SerialNumberID) into a plain string, dropping trailing null bytes.
    .PARAMETER Bytes
        The UInt16[] array from the WMI property.
    .OUTPUTS
        [String] the decoded text, or $null if the array was empty/all-null.
    #>
    param([Object[]]$Bytes)
    if (-not $Bytes) { return $null }
    $chars = $Bytes | Where-Object { $_ -ne 0 } | ForEach-Object { [char]$_ }
    if ($chars.Count -eq 0) { return $null }
    return -join $chars
}

function Get-MonitorInventory {
    <#
    .SYNOPSIS
        Reads manufacturer/model/serial for every connected monitor via EDID data.
        Laptop-internal panels frequently leave UserFriendlyName/SerialNumberID blank
        even when ManufacturerName is populated - that's a real limitation of what
        the panel itself reports over EDID, not a parsing failure, and is left as
        $null rather than guessed at.
    .OUTPUTS
        [System.Collections.Generic.List[pscustomobject]] one entry per monitor:
        { Manufacturer; ModelName; SerialNumber }.
    #>
    $monitors = New-Object System.Collections.Generic.List[Object]
    try {
        $edids = @(Get-CimInstance -Namespace 'root\wmi' -ClassName WmiMonitorID -ErrorAction Stop)
        foreach ($m in $edids) {
            $monitors.Add([pscustomobject]@{
                Manufacturer = ConvertFrom-EdidBytes -Bytes $m.ManufacturerName
                ModelName    = ConvertFrom-EdidBytes -Bytes $m.UserFriendlyName
                SerialNumber = ConvertFrom-EdidBytes -Bytes $m.SerialNumberID
            })
        }
    } catch {
        Write-InventoryLog -Severity Warning -Message "WmiMonitorID lookup failed (device may have no connected display, e.g. headless): $_"
    }
    return $monitors
}

function Get-LastBootTimeUtc {
    <#
    .SYNOPSIS
        Reads when the OS last booted, in UTC ISO 8601 - useful for spotting devices
        that never restart (and so never pick up patches requiring a reboot).
    .OUTPUTS
        [String] ISO 8601 UTC timestamp, or $null if it couldn't be determined.
    #>
    try {
        $os = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop
        return $os.LastBootUpTime.ToUniversalTime().ToString('o')
    } catch {
        Write-InventoryLog -Severity Warning -Message "Win32_OperatingSystem LastBootUpTime lookup failed: $_"
        return $null
    }
}

function Get-BoardChassisBiosInventory {
    <#
    .SYNOPSIS
        Reads identifying details and serial numbers for the motherboard, chassis,
        and BIOS/system - the physical-asset identifiers a device's own OS-visible
        fields (model/manufacturer, already tracked via Graph) don't capture.
    .OUTPUTS
        [pscustomobject] { BoardManufacturer; BoardModel; BoardSerial;
        ChassisManufacturer; ChassisSerial; BiosSerial } - fields are $null on failure.
    #>
    $result = [pscustomobject]@{
        BoardManufacturer   = $null; BoardModel = $null; BoardSerial = $null
        ChassisManufacturer = $null; ChassisSerial = $null
        BiosSerial          = $null
    }
    try {
        $board = Get-CimInstance -ClassName Win32_BaseBoard -ErrorAction Stop | Select-Object -First 1
        $result.BoardManufacturer = if ($board.Manufacturer) { $board.Manufacturer.Trim() } else { $null }
        $result.BoardModel = if ($board.Product) { $board.Product.Trim() } else { $null }
        $result.BoardSerial = if ($board.SerialNumber) { $board.SerialNumber.Trim() } else { $null }
    } catch {
        Write-InventoryLog -Severity Warning -Message "Win32_BaseBoard lookup failed: $_"
    }
    try {
        $chassis = Get-CimInstance -ClassName Win32_SystemEnclosure -ErrorAction Stop | Select-Object -First 1
        $result.ChassisManufacturer = if ($chassis.Manufacturer) { $chassis.Manufacturer.Trim() } else { $null }
        $result.ChassisSerial = if ($chassis.SerialNumber) { $chassis.SerialNumber.Trim() } else { $null }
    } catch {
        Write-InventoryLog -Severity Warning -Message "Win32_SystemEnclosure lookup failed: $_"
    }
    try {
        $bios = Get-CimInstance -ClassName Win32_BIOS -ErrorAction Stop | Select-Object -First 1
        $result.BiosSerial = if ($bios.SerialNumber) { $bios.SerialNumber.Trim() } else { $null }
    } catch {
        Write-InventoryLog -Severity Warning -Message "Win32_BIOS lookup failed: $_"
    }
    return $result
}

function Get-FirmwareInventory {
    <#
    .SYNOPSIS
        Determines whether Windows actually booted via UEFI or the legacy/CSM path,
        and whether Secure Boot is enabled. There is no OS-visible way to read "is
        CSM enabled" as a standalone firmware toggle - BiosFirmwareType reflects how
        Windows itself booted, which is the meaningful signal in practice: if CSM is
        active, Windows boots legacy and this reports 'Legacy'.
    .OUTPUTS
        [pscustomobject] { FirmwareType ('Uefi'/'Legacy'/$null); SecureBootEnabled
        ([bool] or $null if it couldn't be determined, e.g. legacy BIOS has no concept
        of Secure Boot) }
    #>
    $result = [pscustomobject]@{ FirmwareType = $null; SecureBootEnabled = $null }
    try {
        $result.FirmwareType = (Get-ComputerInfo -Property BiosFirmwareType -ErrorAction Stop).BiosFirmwareType.ToString()
    } catch {
        Write-InventoryLog -Severity Warning -Message "Get-ComputerInfo BiosFirmwareType failed: $_"
    }
    try {
        # Throws on legacy BIOS ("not supported on this platform") rather than
        # returning $false - that case is left as $null (unknown/not applicable)
        # rather than misreported as "Secure Boot off".
        $result.SecureBootEnabled = [bool](Confirm-SecureBootUEFI -ErrorAction Stop)
    } catch {
        Write-InventoryLog -Message "Confirm-SecureBootUEFI not available (expected on legacy/CSM boot): $_"
    }
    return $result
}

function Get-TpmInventory {
    <#
    .SYNOPSIS
        Reads TPM state, capability, and attestation-readiness facts. Attestation
        readiness comes from `tpmtool.exe GetDeviceInformation`'s own "Ready For
        Attestation" / "Is Capable For Attestation" fields - this is Microsoft's own
        computed determination (accounts for EK certificate validity, PCR banks,
        etc.), not an approximation built from raw TPM state here. This is a real,
        locally-checkable signal - not a live attestation call to Microsoft's Device
        Directory Service, so it can still occasionally disagree with what a real
        Autopilot enrollment attempt reports, but it is authoritative rather than a
        guess.
    .OUTPUTS
        [pscustomobject] { Present; Enabled; Activated; Owned; SpecVersion;
        ManufacturerId; ManufacturerVersion; EkCertPresent; ReadyForAttestation;
        CapableForAttestation; VulnerableFirmware; BitlockerPcr7BindingState }
    #>
    $result = [pscustomobject]@{
        Present = $null; Enabled = $null; Activated = $null; Owned = $null
        SpecVersion = $null; ManufacturerId = $null; ManufacturerVersion = $null
        EkCertPresent = $null
        ReadyForAttestation = $null; CapableForAttestation = $null
        VulnerableFirmware = $null; BitlockerPcr7BindingState = $null
    }

    try {
        $tpm = Get-Tpm -ErrorAction Stop
        $result.Present = [bool]$tpm.TpmPresent
        $result.Enabled = [bool]$tpm.TpmEnabled
        $result.Activated = [bool]$tpm.TpmActivated
        $result.Owned = [bool]$tpm.TpmOwned
        $result.ManufacturerId = $tpm.ManufacturerIdTxt
        $result.ManufacturerVersion = $tpm.ManufacturerVersion
    } catch {
        Write-InventoryLog -Severity Warning -Message "Get-Tpm failed (requires admin - should not happen running as SYSTEM): $_"
    }

    try {
        $win32Tpm = Get-CimInstance -Namespace 'root\cimv2\Security\MicrosoftTpm' -ClassName Win32_Tpm -ErrorAction Stop
        $result.SpecVersion = $win32Tpm.SpecVersion
    } catch {
        Write-InventoryLog -Severity Warning -Message "Win32_Tpm SpecVersion lookup failed: $_"
    }

    try {
        $ek = Get-TpmEndorsementKeyInfo -HashAlgorithm Sha256 -ErrorAction Stop
        $result.EkCertPresent = [bool]$ek.IsPresent
    } catch {
        Write-InventoryLog -Severity Warning -Message "Get-TpmEndorsementKeyInfo failed: $_"
    }

    try {
        $tpmToolOutput = & tpmtool.exe getdeviceinformation 2>$null
        foreach ($line in $tpmToolOutput) {
            if ($line -match '^-Ready For Attestation:\s*(True|False)$') { $result.ReadyForAttestation = [bool]::Parse($Matches[1]) }
            elseif ($line -match '^-Is Capable For Attestation:\s*(True|False)$') { $result.CapableForAttestation = [bool]::Parse($Matches[1]) }
            elseif ($line -match '^-TPM Has Vulnerable Firmware:\s*(True|False)$') { $result.VulnerableFirmware = [bool]::Parse($Matches[1]) }
            elseif ($line -match '^-Bitlocker PCR7 Binding State:\s*(.+)$') { $result.BitlockerPcr7BindingState = $Matches[1].Trim() }
        }
        if ($null -eq $result.ReadyForAttestation) {
            Write-InventoryLog -Severity Warning -Message "tpmtool.exe output did not contain 'Ready For Attestation' - parsing may need updating for this Windows build."
        }
    } catch {
        Write-InventoryLog -Severity Warning -Message "tpmtool.exe getdeviceinformation failed: $_"
    }

    return $result
}

function ConvertTo-LinkSpeedBps {
    <#
    .SYNOPSIS
        Parses Get-NetAdapter's human-readable LinkSpeed string (e.g. "1 Gbps",
        "413 Mbps") into a plain bits-per-second integer for storage/querying.
    .PARAMETER LinkSpeed
        The LinkSpeed string from Get-NetAdapter.
    .OUTPUTS
        [Int64] bits per second, or $null if it couldn't be parsed.
    #>
    param([String]$LinkSpeed)
    if ([string]::IsNullOrWhiteSpace($LinkSpeed)) { return $null }
    if ($LinkSpeed -match '^([\d.]+)\s*(Gbps|Mbps|Kbps|bps)$') {
        $value = [double]$Matches[1]
        $multiplier = switch ($Matches[2]) {
            'Gbps' { 1000000000 }
            'Mbps' { 1000000 }
            'Kbps' { 1000 }
            default { 1 }
        }
        return [int64]($value * $multiplier)
    }
    return $null
}

function Get-ConnectedSsidByInterfaceName {
    <#
    .SYNOPSIS
        Parses `netsh wlan show interfaces` to map each wireless interface name to
        its currently-connected SSID, if any. Returns an empty map (not an error) on
        a device with no wireless capability at all - netsh reports "There is no
        wireless interface on the system" in that case, which is a normal outcome,
        not a failure.
    .OUTPUTS
        [hashtable] interface name -> SSID, only for interfaces currently connected.
    #>
    $map = @{}
    try {
        $output = & netsh wlan show interfaces 2>$null
    } catch {
        Write-InventoryLog -Message "netsh wlan show interfaces failed (device may have no wireless adapter): $_"
        return $map
    }
    $currentName = $null
    foreach ($line in $output) {
        if ($line -match '^\s*Name\s*:\s*(.+)$') { $currentName = $Matches[1].Trim() }
        elseif ($line -match '^\s*SSID\s*:\s*(.+)$' -and $currentName) {
            $map[$currentName] = $Matches[1].Trim()
        }
    }
    return $map
}

function Get-IpConfigByInterfaceAlias {
    <#
    .SYNOPSIS
        Maps each interface's alias to its IPv4 address, subnet prefix length,
        default gateway, and the gateway's MAC address (resolved via the ARP/
        neighbor cache) - the "which network segment is this device on" signal used
        to infer physical location (building/floor) from network topology, since
        Windows has no direct API for that.
    .OUTPUTS
        [hashtable] interface alias -> pscustomobject { IPAddress; PrefixLength;
        Gateway; GatewayMac }.
    #>
    $map = @{}
    try {
        $configs = @(Get-NetIPConfiguration -ErrorAction Stop | Where-Object { $_.IPv4Address })
        foreach ($c in $configs) {
            $gatewayIp = $c.IPv4DefaultGateway.NextHop
            $gatewayMac = $null
            if ($gatewayIp) {
                try {
                    $neighbor = Get-NetNeighbor -IPAddress $gatewayIp -ErrorAction Stop | Select-Object -First 1
                    if ($neighbor -and $neighbor.LinkLayerAddress -ne '00-00-00-00-00-00') { $gatewayMac = $neighbor.LinkLayerAddress }
                } catch {
                    # ARP/neighbor entry not yet resolved - not worth logging, common
                    # and harmless (just means no gateway MAC for this run).
                }
            }
            $map[$c.InterfaceAlias] = [pscustomobject]@{
                IPAddress    = ($c.IPv4Address | Select-Object -First 1).IPAddress
                PrefixLength = ($c.IPv4Address | Select-Object -First 1).PrefixLength
                Gateway      = $gatewayIp
                GatewayMac   = $gatewayMac
            }
        }
    } catch {
        Write-InventoryLog -Severity Warning -Message "Get-NetIPConfiguration failed: $_"
    }
    return $map
}

function Get-NetworkAdapterInventory {
    <#
    .SYNOPSIS
        Reads every network adapter's name, MAC, media type, link speed, status,
        currently-connected SSID (wireless), and IP/gateway configuration (the
        network-location signal - see Get-IpConfigByInterfaceAlias).
    .OUTPUTS
        [System.Collections.Generic.List[pscustomobject]] one entry per adapter with
        a MAC address; adapters without one (some virtual/loopback interfaces) are
        skipped since MAC is the correlation key on the receiving end.
    #>
    $adapters = New-Object System.Collections.Generic.List[Object]
    try {
        $ssidByName = Get-ConnectedSsidByInterfaceName
        $ipByAlias = Get-IpConfigByInterfaceAlias
        $netAdapters = @(Get-NetAdapter -ErrorAction Stop)
        foreach ($a in $netAdapters) {
            if (-not $a.MacAddress) { continue }
            $ip = $ipByAlias[$a.Name]
            $adapters.Add([pscustomobject]@{
                Name              = $a.Name
                MacAddress        = $a.MacAddress
                MediaType         = [string]$a.MediaType
                PhysicalMediaType = [string]$a.PhysicalMediaType
                LinkSpeedBps      = ConvertTo-LinkSpeedBps -LinkSpeed ([string]$a.LinkSpeed)
                Status            = [string]$a.Status
                ConnectedSsid     = $ssidByName[$a.Name]
                IpAddress         = if ($ip) { $ip.IPAddress } else { $null }
                SubnetPrefixLength = if ($ip) { $ip.PrefixLength } else { $null }
                DefaultGateway    = if ($ip) { $ip.Gateway } else { $null }
                GatewayMacAddress = if ($ip) { $ip.GatewayMac } else { $null }
            })
        }
    } catch {
        Write-InventoryLog -Severity Warning -Message "Get-NetAdapter failed: $_"
    }
    return $adapters
}

function Get-WinSatInventory {
    <#
    .SYNOPSIS
        Reads Windows' own cached WinSAT (Windows System Assessment Tool) hardware
        performance scores via the Win32_WinSAT CIM class - a free supplementary
        signal alongside the CPU throughput benchmark (Invoke-CpuBenchmark.ps1),
        since Windows already computes and caches these; no benchmark runs here,
        just an instant read. Not capturing WinSPRLevel ("the overall score") -
        it's just MIN() of the five component scores below, so it's redundant to
        store separately; trivially recomputable from these if ever wanted.

        This is a snapshot from whenever WinSAT last ran - often once, near first
        boot/imaging - so on an older device it can reflect hardware state from
        years ago (e.g. before a RAM upgrade), not necessarily today's. Treat as a
        free corroborating signal, not a substitute for the CPU throughput
        benchmark, which is deliberately measured fresh every run.
    .OUTPUTS
        [pscustomobject] { CpuScore; D3dScore; DiskScore; GraphicsScore;
        MemoryScore; AssessmentState } - all $null/'Unknown' if WinSAT has never
        run or the class is unavailable on this SKU.
    #>
    $result = [pscustomobject]@{
        CpuScore = $null; D3dScore = $null; DiskScore = $null; GraphicsScore = $null
        MemoryScore = $null; AssessmentState = $null
    }
    try {
        $winsat = Get-CimInstance -ClassName Win32_WinSAT -ErrorAction Stop
        if ($winsat) {
            # Win32_WinSAT's own documented WINSAT_ASSESSMENT_STATE enum.
            $stateMap = @{ 0 = 'Unknown'; 1 = 'Valid'; 2 = 'IncoherentWithHardware'; 3 = 'NoAssessmentAvailable'; 4 = 'Invalid' }
            $result.CpuScore = $winsat.CPUScore
            $result.D3dScore = $winsat.D3DScore
            $result.DiskScore = $winsat.DiskScore
            $result.GraphicsScore = $winsat.GraphicsScore
            $result.MemoryScore = $winsat.MemoryScore
            $state = [int]$winsat.WinSATAssessmentState
            $result.AssessmentState = if ($stateMap.ContainsKey($state)) { $stateMap[$state] } else { 'Unknown' }
        }
    } catch {
        Write-InventoryLog -Severity Warning -Message "WinSAT lookup failed: $_"
    }
    return $result
}

function Get-GeoLocation {
    <#
    .SYNOPSIS
        Attempts a Windows Location API fix (GPS or Wi-Fi positioning) with a bounded
        timeout. Running as SYSTEM (this task's context), this will very likely fail
        or time out - location consent is normally an interactive per-user privacy
        setting under Settings > Privacy > Location, and SYSTEM has no such consent
        granted by default. It CAN succeed if the organization has an MDM policy
        forcing location access on for all apps/users at the machine level (the
        "AllowLocation" CSP / equivalent Intune configuration profile setting) -
        implemented so it works automatically if that's ever configured, rather than
        assuming it never will be. Denied/unavailable is logged and reported as no
        location, not an error - this is an expected, common outcome.
    .PARAMETER TimeoutSeconds
        How long to wait for a fix before giving up.
    .OUTPUTS
        [pscustomobject] { Latitude; Longitude; AccuracyMeters; Source } - all fields
        $null if no fix was obtained.
    #>
    param([Int32]$TimeoutSeconds = 10)

    $result = [pscustomobject]@{ Latitude = $null; Longitude = $null; AccuracyMeters = $null; Source = $null }
    $watcher = $null
    try {
        Add-Type -AssemblyName System.Device -ErrorAction Stop
        $watcher = New-Object System.Device.Location.GeoCoordinateWatcher
        $watcher.Start()
        $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
        while ($watcher.Status -ne 'Ready' -and (Get-Date) -lt $deadline -and $watcher.Permission -ne 'Denied') {
            Start-Sleep -Milliseconds 250
        }
        Write-InventoryLog -Message "Windows Location API: Status=$($watcher.Status) Permission=$($watcher.Permission)."
        if ($watcher.Status -eq 'Ready' -and -not $watcher.Position.Location.IsUnknown) {
            $loc = $watcher.Position.Location
            $result.Latitude = $loc.Latitude
            $result.Longitude = $loc.Longitude
            $result.AccuracyMeters = $loc.HorizontalAccuracy
            $result.Source = 'WindowsLocationApi'
        }
    } catch {
        Write-InventoryLog -Message "Windows Location API unavailable: $_"
    } finally {
        if ($watcher) { $watcher.Stop(); $watcher.Dispose() }
    }
    return $result
}

function Read-InventoryConfigFile {
    <#
    .SYNOPSIS
        Reads and parses the JSON config file (ingest URL + non-secret settings).
        Deliberately holds no secret - see Get-IngestClientCertificate for why.
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

function Get-IngestClientCertificate {
    <#
    .SYNOPSIS
        Finds the client certificate used to authenticate to the ingest endpoint
        (mutual TLS), by subject CN, in the local machine certificate store.
        Deliberately NOT a secret shipped inside this Win32 app's package or read
        from a plaintext file - this app's source (including its packaged content)
        lives in a PUBLIC GitHub repo, and a static shared-secret approach was tried
        first and had to be abandoned after it leaked that way.

        The certificate is delivered by this app's own installer
        (Install-IngestClientCertificate in Invoke-AppDeployToolkit.ps1), which
        imports a PFX injected into the package at CI build time from GitHub repo
        secrets - see this app's README, "Ingest authentication", for the full
        design and why an Intune Certificate profile was considered and ruled out
        (both PKCS variants require the Certificate Connector for Microsoft Intune,
        which needs Windows Server infrastructure this org doesn't have).
    .PARAMETER SubjectCn
        The certificate's expected Subject Common Name.
    .OUTPUTS
        [System.Security.Cryptography.X509Certificates.X509Certificate2] the
        certificate, or $null if no match was found in the local machine store.
    #>
    param([Parameter(Mandatory)][String]$SubjectCn)
    try {
        $cert = Get-ChildItem -Path 'Cert:\LocalMachine\My' -ErrorAction Stop |
            Where-Object { $_.Subject -eq "CN=$SubjectCn" -and $_.HasPrivateKey } |
            Sort-Object NotAfter -Descending | Select-Object -First 1
        if (-not $cert) {
            Write-InventoryLog -Severity Error -Message "No certificate with subject 'CN=$SubjectCn' and a private key found in Cert:\LocalMachine\My - has the Intune Certificate profile that delivers it been assigned to this device yet? See README."
            return $null
        }
        return $cert
    } catch {
        Write-InventoryLog -Severity Error -Message "Certificate store lookup failed: $_"
        return $null
    }
}

#region Main
Write-InventoryLog -Message 'Starting device inventory collection.'

$config = Read-InventoryConfigFile -Path $ConfigPath
if (-not $config -or -not $config.IngestUrl) {
    Write-InventoryLog -Severity Error -Message 'Missing IngestUrl in config - aborting.'
    exit 1
}

$ingestClientCn = if ($config.IngestClientCertSubjectCn) { $config.IngestClientCertSubjectCn } else { 'dashhouse-device-ingest-client' }
$ingestCert = Get-IngestClientCertificate -SubjectCn $ingestClientCn
if (-not $ingestCert) {
    Write-InventoryLog -Severity Error -Message 'Could not obtain ingest client certificate - aborting.'
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
$boardChassisBios = Get-BoardChassisBiosInventory
$firmware = Get-FirmwareInventory
$tpm = Get-TpmInventory
$networkAdapters = Get-NetworkAdapterInventory
$localAdmins = Get-LocalAdministratorInventory
$defender = Get-DefenderInventory
$pendingReboot = Test-PendingReboot
$activationStatus = Get-WindowsActivationStatus
$battery = Get-BatteryInventory
$monitors = Get-MonitorInventory
$lastBootTimeUtc = Get-LastBootTimeUtc
$geoLocation = Get-GeoLocation
$winsat = Get-WinSatInventory

$collectedAtUtc = (Get-Date).ToUniversalTime().ToString('o')

$payload = @{
    azureAdDeviceId        = $azureAdDeviceId
    deviceName              = $env:COMPUTERNAME
    cpuModel                = $cpu.Model
    cpuCores                = $cpu.Cores
    cpuLogicalProcessors    = $cpu.LogicalProcessors
    cpuProcessorId           = $cpu.ProcessorId
    gpuModel                = $gpuModel
    diskModel                = $disk.Model
    diskMediaType            = $disk.MediaType
    diskSerial               = $disk.Serial
    boardManufacturer        = $boardChassisBios.BoardManufacturer
    boardModel               = $boardChassisBios.BoardModel
    boardSerial              = $boardChassisBios.BoardSerial
    chassisManufacturer      = $boardChassisBios.ChassisManufacturer
    chassisSerial            = $boardChassisBios.ChassisSerial
    biosSerial               = $boardChassisBios.BiosSerial
    firmwareType              = $firmware.FirmwareType
    secureBootEnabled         = $firmware.SecureBootEnabled
    tpmPresent               = $tpm.Present
    tpmEnabled               = $tpm.Enabled
    tpmActivated             = $tpm.Activated
    tpmOwned                 = $tpm.Owned
    tpmSpecVersion           = $tpm.SpecVersion
    tpmManufacturerId         = $tpm.ManufacturerId
    tpmManufacturerVersion    = $tpm.ManufacturerVersion
    tpmEkCertPresent          = $tpm.EkCertPresent
    tpmReadyForAttestation    = $tpm.ReadyForAttestation
    tpmCapableForAttestation  = $tpm.CapableForAttestation
    tpmVulnerableFirmware     = $tpm.VulnerableFirmware
    tpmBitlockerPcr7BindingState = $tpm.BitlockerPcr7BindingState
    diskHealthStatus         = $disk.HealthStatus
    diskWearPercentage        = $disk.WearPercentage
    diskTemperatureCelsius    = $disk.TemperatureCelsius
    diskPowerOnHours          = $disk.PowerOnHours
    diskReadErrorsTotal       = $disk.ReadErrorsTotal
    diskWriteErrorsTotal      = $disk.WriteErrorsTotal
    pendingReboot             = $pendingReboot
    windowsActivationStatus   = $activationStatus
    defenderAntivirusEnabled  = $defender.AntivirusEnabled
    defenderRealtimeProtectionEnabled = $defender.RealtimeProtectionEnabled
    defenderSignatureAgeDays  = $defender.SignatureAgeDays
    defenderLastQuickScan     = $defender.LastQuickScan
    defenderLastFullScan      = $defender.LastFullScan
    batteryDesignCapacityMwh   = $battery.DesignCapacityMwh
    batteryFullChargeCapacityMwh = $battery.FullChargeCapacityMwh
    batteryCycleCount         = $battery.CycleCount
    lastBootTimeUtc           = $lastBootTimeUtc
    locationLatitude          = $geoLocation.Latitude
    locationLongitude         = $geoLocation.Longitude
    locationAccuracyMeters    = $geoLocation.AccuracyMeters
    locationSource            = $geoLocation.Source
    winsatCpuScore            = $winsat.CpuScore
    winsatD3dScore            = $winsat.D3dScore
    winsatDiskScore           = $winsat.DiskScore
    winsatGraphicsScore       = $winsat.GraphicsScore
    winsatMemoryScore         = $winsat.MemoryScore
    winsatAssessmentState     = $winsat.AssessmentState
    collectedAtUtc           = $collectedAtUtc
    networkAdapters          = @($networkAdapters | ForEach-Object {
        @{
            name              = $_.Name
            macAddress        = $_.MacAddress
            mediaType         = $_.MediaType
            physicalMediaType = $_.PhysicalMediaType
            linkSpeedBps      = $_.LinkSpeedBps
            status            = $_.Status
            connectedSsid     = $_.ConnectedSsid
            ipAddress          = $_.IpAddress
            subnetPrefixLength = $_.SubnetPrefixLength
            defaultGateway     = $_.DefaultGateway
            gatewayMacAddress  = $_.GatewayMacAddress
        }
    })
    localAdmins              = @($localAdmins | ForEach-Object {
        @{
            name           = $_.Name
            sid            = $_.Sid
            objectClass    = $_.ObjectClass
            isLocalAccount = $_.IsLocalAccount
        }
    })
    monitors                 = @($monitors | ForEach-Object {
        @{
            manufacturer = $_.Manufacturer
            modelName    = $_.ModelName
            serialNumber = $_.SerialNumber
        }
    })
} | ConvertTo-Json -Compress -Depth 5

Write-InventoryLog -Message "Collected: CPU='$($cpu.Model)', Board='$($boardChassisBios.BoardManufacturer) $($boardChassisBios.BoardModel)', Firmware='$($firmware.FirmwareType)', SecureBoot=$($firmware.SecureBootEnabled), TPM present/enabled/activated/owned=$($tpm.Present)/$($tpm.Enabled)/$($tpm.Activated)/$($tpm.Owned) spec=$($tpm.SpecVersion) ekCert=$($tpm.EkCertPresent) readyForAttestation=$($tpm.ReadyForAttestation) capableForAttestation=$($tpm.CapableForAttestation), NICs=$(@($networkAdapters).Count), LocalAdmins=$(@($localAdmins).Count), Defender AV/RTP=$($defender.AntivirusEnabled)/$($defender.RealtimeProtectionEnabled), PendingReboot=$pendingReboot, Activation=$activationStatus, BatteryDesign/Full/Cycles=$($battery.DesignCapacityMwh)/$($battery.FullChargeCapacityMwh)/$($battery.CycleCount), Monitors=$(@($monitors).Count), GeoLocation=$($geoLocation.Source) lat/long=$($geoLocation.Latitude)/$($geoLocation.Longitude)."

try {
    # Windows PowerShell 5.1's Invoke-RestMethod does not reliably send a plain
    # [String] body as UTF-8 (it can fall back to the system's ANSI codepage),
    # which silently mangles non-ASCII characters - observed with a Swedish adapter
    # name ("nätverksanslutning") arriving as "n?tverksanslutning" server-side.
    # Encoding the body to UTF-8 bytes explicitly avoids that.
    $payloadBytes = [System.Text.Encoding]::UTF8.GetBytes($payload)
    $response = Invoke-RestMethod -Method Post -Uri $config.IngestUrl -Body $payloadBytes -ContentType 'application/json; charset=utf-8' `
        -Certificate $ingestCert -TimeoutSec 30
    Write-InventoryLog -Message "Report sent successfully for device ID '$azureAdDeviceId'. Response: $($response | ConvertTo-Json -Compress)"
} catch {
    Write-InventoryLog -Severity Error -Message "Failed to send report: $_"
    exit 1
}
#endregion
