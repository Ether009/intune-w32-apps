#Requires -Version 5.1
<#
.SYNOPSIS
    Runs a short, fixed-work single-threaded CPU benchmark and reports the elapsed
    time to the Dashhouse Admin UI, so relatively low-performing CPUs in the fleet
    can be identified directly - CPU generation alone is a rough proxy, since two
    CPUs from the same generation (a U-series vs a T-series SKU, for example) can
    still differ meaningfully in real throughput.

.DESCRIPTION
    Runs as NT AUTHORITY\SYSTEM from a scheduled task that Task Scheduler itself
    only starts once the device has been idle for a while (a native "run only if
    idle" trigger condition, not custom idle-detection code in this script - see
    Register-CpuBenchmarkScheduledTask in Invoke-AppDeployToolkit.ps1 for why: this
    script runs in session 0, where APIs like GetLastInputInfo() cannot see the
    interactive user's session at all, so a hand-rolled idle check from in here
    would silently be wrong). A benchmark competing with whatever the person using
    the device is actually doing would both slow them down and produce a
    meaningless result, so this script trusts Task Scheduler entirely for that and
    has no idle logic of its own.

    Measures two things, both fixed-work (not fixed-*duration*) SHA-256 hashing so
    elapsed milliseconds is directly comparable across devices - lower is faster:
      - Single-core: one thread, sequential.
      - Multi-core: the same per-thread workload run N-way in parallel across every
        logical processor. Total work scales with core count on purpose - a device
        that can genuinely put more cores to use finishes sooner, which is the real
        multi-core capability this is meant to capture, not something to normalize
        away.
    Neither is a portable/absolute benchmark score - both are relative fleet-ranking
    signals only, not comparable to results from other tools.

    Posts the device ID and both measured times to a narrow endpoint
    (`/api/inventory/benchmark`) that updates exactly those columns on the device's
    existing inventory row. Deliberately not the same endpoint Get-DeviceInventory.ps1
    uses - that one's UPDATE spans every column in its payload, so a small
    benchmark-only POST through it would null out every other field this script does
    not collect.

.NOTES
    Deployed to disk by the PSADT Win32 app alongside Get-DeviceInventory.ps1;
    invoked by the "Organization - CPU Benchmark" scheduled task. Harmless to run
    manually/interactively for testing - it only measures local CPU throughput and
    posts a two-field report.
#>
[CmdletBinding()]
param (
    [String]$ConfigPath,
    [String]$LogPath = (Join-Path $env:ProgramData 'Organization\DeviceInventory\Logs\Invoke-CpuBenchmark.log')
)

if ([string]::IsNullOrWhiteSpace($ConfigPath)) { $ConfigPath = Join-Path $PSScriptRoot 'DeviceInventoryConfig.json' }

$ErrorActionPreference = 'Stop'

function Write-BenchmarkLog {
    <#
    .SYNOPSIS
        Appends one line to the run's log file, rotating it if it has grown past 2MB.
        Never throws - logging must not be able to break the run. Deliberately a
        separate log file from Get-DeviceInventory.ps1's, even though both scripts
        share this same function body, so the two tasks never contend over rotating
        the same file if they happen to run close together.
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
        Same identifier Get-DeviceInventory.ps1 reports and Dashhouse's central
        Intune sync stores as `azure_ad_device_id`, so this script's report attaches
        to the same existing device row.
    .OUTPUTS
        [String] the device GUID, or $null if the device isn't Azure AD joined or the
        output could not be parsed.
    #>
    try {
        $status = & dsregcmd /status 2>$null
    } catch {
        Write-BenchmarkLog -Severity Error -Message "dsregcmd /status failed to run: $_"
        return $null
    }
    $line = $status | Select-String -Pattern '^\s*DeviceId\s*:\s*(\S+)' | Select-Object -First 1
    if (-not $line) {
        Write-BenchmarkLog -Severity Warning -Message 'Could not find DeviceId in dsregcmd /status output - device may not be Azure AD joined.'
        return $null
    }
    return $line.Matches[0].Groups[1].Value
}

function Read-BenchmarkConfigFile {
    <#
    .SYNOPSIS
        Reads and parses the JSON config file shared with Get-DeviceInventory.ps1.
        Deliberately holds no secret - see Get-IngestClientCertificate below.
    .PARAMETER Path
        Full path to the JSON config file.
    .OUTPUTS
        The parsed JSON object, or $null on failure.
    #>
    param([Parameter(Mandatory)][String]$Path)
    if (-not (Test-Path -LiteralPath $Path)) {
        Write-BenchmarkLog -Severity Error -Message "Config file not found at '$Path'."
        return $null
    }
    try {
        return Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json
    } catch {
        Write-BenchmarkLog -Severity Error -Message "Failed to parse config file '$Path': $_"
        return $null
    }
}

function Get-IngestClientCertificate {
    <#
    .SYNOPSIS
        Finds the same mutual-TLS client certificate Get-DeviceInventory.ps1 uses,
        by subject CN, in the local machine certificate store. See that script for
        why this is looked up from the store rather than shipped as a file/secret.
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
            Write-BenchmarkLog -Severity Error -Message "No certificate with subject 'CN=$SubjectCn' and a private key found in Cert:\LocalMachine\My."
            return $null
        }
        return $cert
    } catch {
        Write-BenchmarkLog -Severity Error -Message "Certificate store lookup failed: $_"
        return $null
    }
}

function Measure-CpuBenchmark {
    <#
    .SYNOPSIS
        Single-threaded, fixed-work SHA-256 hashing benchmark: hashes a 4MB buffer
        50 times (200MB total) and times it. Fixed work rather than fixed duration,
        so the result (elapsed ms) is directly comparable across devices - lower is
        faster. Sized to take roughly a few seconds even on the oldest CPUs
        currently in the fleet (4th/5th-gen Intel U-series) without running long
        enough to matter if it's a bit off for a much newer or much older machine.
    .OUTPUTS
        [Double] elapsed milliseconds - lower is a faster CPU.
    #>
    $bufferSizeBytes = 4MB
    $iterations = 50

    $buffer = New-Object byte[] $bufferSizeBytes
    (New-Object System.Random).NextBytes($buffer)

    $sha256 = [System.Security.Cryptography.SHA256]::Create()
    try {
        $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
        for ($i = 0; $i -lt $iterations; $i++) {
            [void]$sha256.ComputeHash($buffer)
        }
        $stopwatch.Stop()
    } finally {
        $sha256.Dispose()
    }
    return $stopwatch.Elapsed.TotalMilliseconds
}

function Measure-CpuBenchmarkMultiCore {
    <#
    .SYNOPSIS
        Same fixed-work SHA-256 hashing as Measure-CpuBenchmark, run N-way in
        parallel (N = logical processor count) via a runspace pool - each worker
        hashes its own independently-generated buffer, so there's no shared state
        or synchronization between threads to skew the timing.

        A runspace pool rather than PowerShell 7's `ForEach-Object -Parallel`
        because this targets Windows PowerShell 5.1 (same constraint as the rest of
        this app), and rather than passing a scriptblock to a .NET
        [Threading.Tasks.Parallel] delegate because scriptblock-to-delegate capture
        of outer-scope variables across threads is a known PowerShell footgun -
        explicit -AddArgument to each worker's own script instance sidesteps it
        entirely.
    .OUTPUTS
        [Double] wall-clock elapsed milliseconds for every worker to finish its own
        50-iteration hashing pass - lower is faster/more capable.
    #>
    $processorCount = [Math]::Max(1, [Environment]::ProcessorCount)
    $iterationsPerWorker = 50

    $workerScript = {
        param($BufferSizeBytes, $Iterations)
        $buffer = New-Object byte[] $BufferSizeBytes
        (New-Object System.Random).NextBytes($buffer)
        $sha256 = [System.Security.Cryptography.SHA256]::Create()
        try {
            for ($i = 0; $i -lt $Iterations; $i++) { [void]$sha256.ComputeHash($buffer) }
        } finally {
            $sha256.Dispose()
        }
    }

    $pool = [runspacefactory]::CreateRunspacePool(1, $processorCount)
    $pool.Open()
    $workers = @()
    try {
        $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
        for ($i = 0; $i -lt $processorCount; $i++) {
            $shell = [powershell]::Create()
            $shell.RunspacePool = $pool
            [void]$shell.AddScript($workerScript).AddArgument(4MB).AddArgument($iterationsPerWorker)
            $workers += [pscustomobject]@{ Shell = $shell; Handle = $shell.BeginInvoke() }
        }
        foreach ($worker in $workers) {
            $worker.Shell.EndInvoke($worker.Handle) | Out-Null
        }
        $stopwatch.Stop()
    } finally {
        foreach ($worker in $workers) { $worker.Shell.Dispose() }
        $pool.Close()
        $pool.Dispose()
    }
    return $stopwatch.Elapsed.TotalMilliseconds
}

#region Main
Write-BenchmarkLog -Message 'Starting CPU benchmark run (Task Scheduler only starts this task once the device has been idle).'

$config = Read-BenchmarkConfigFile -Path $ConfigPath
if (-not $config -or -not $config.BenchmarkUrl) {
    Write-BenchmarkLog -Severity Error -Message 'Missing BenchmarkUrl in config - aborting.'
    exit 1
}

$ingestClientCn = if ($config.IngestClientCertSubjectCn) { $config.IngestClientCertSubjectCn } else { 'dashhouse-device-ingest-client' }
$ingestCert = Get-IngestClientCertificate -SubjectCn $ingestClientCn
if (-not $ingestCert) {
    Write-BenchmarkLog -Severity Error -Message 'Could not obtain ingest client certificate - aborting.'
    exit 1
}

$azureAdDeviceId = Get-AzureAdDeviceId
if (-not $azureAdDeviceId) {
    Write-BenchmarkLog -Severity Error -Message 'Could not determine this device''s Azure AD device ID - aborting.'
    exit 1
}

$singleCoreMs = [Math]::Round((Measure-CpuBenchmark), 1)
Write-BenchmarkLog -Message "Single-core benchmark complete: $singleCoreMs ms."

$multiCoreMs = [Math]::Round((Measure-CpuBenchmarkMultiCore), 1)
Write-BenchmarkLog -Message "Multi-core benchmark complete ($([Environment]::ProcessorCount) logical processors): $multiCoreMs ms."

$payload = [pscustomobject]@{
    azureAdDeviceId       = $azureAdDeviceId
    cpuBenchmarkMs        = $singleCoreMs
    cpuBenchmarkMultiCoreMs = $multiCoreMs
} | ConvertTo-Json -Compress

# Explicit UTF-8 byte encoding - Windows PowerShell 5.1's Invoke-RestMethod does not
# reliably send a plain [String] body as UTF-8 on its own (same fix as the other
# script; the device ID here is ASCII-only so this particular payload wouldn't
# actually hit that bug, but keeping the same pattern avoids a footgun later if this
# payload ever grows a field that isn't).
$payloadBytes = [System.Text.Encoding]::UTF8.GetBytes($payload)

try {
    $response = Invoke-RestMethod -Method Post -Uri $config.BenchmarkUrl -Body $payloadBytes -ContentType 'application/json; charset=utf-8' `
        -Certificate $ingestCert -TimeoutSec 30
    Write-BenchmarkLog -Message "Benchmark result sent successfully for device ID '$azureAdDeviceId'. Response: $($response | ConvertTo-Json -Compress)"
} catch {
    Write-BenchmarkLog -Severity Error -Message "Failed to send benchmark result: $_"
    exit 1
}
#endregion
