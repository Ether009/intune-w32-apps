#Requires -Version 5.1
<#
.SYNOPSIS
    Runs a fixed-duration CPU throughput benchmark and reports the result to the
    Dashhouse Admin UI, so relatively low-performing CPUs in the fleet can be
    identified directly - CPU generation alone is a rough proxy, since two CPUs
    from the same generation (a U-series vs a T-series SKU, for example) can
    still differ meaningfully in real throughput.

.DESCRIPTION
    Invoked by two different scheduled tasks with different -DurationSeconds
    values (see Register-CpuBenchmarkIdleScheduledTask and
    Register-CpuBenchmarkForcedScheduledTask in Invoke-AppDeployToolkit.ps1):
    a primary idle-gated task (120s/phase, high accuracy) and a weekly
    not-idle-gated fallback (30s/phase, for devices that rarely go idle). The
    idle-gated task relies entirely on Task Scheduler's own idle engine
    (-RunOnlyIfIdle), not custom idle-detection code in this script - this runs
    as NT AUTHORITY\SYSTEM in session 0, where APIs like GetLastInputInfo()
    cannot see the interactive user's session at all, so a hand-rolled idle
    check from in here would silently be wrong.

    Measures two things, both fixed-DURATION (not fixed-work) throughput
    calculating digits of pi via the classic Rabinowitz-Wagon spigot algorithm
    (arbitrary-precision integer arithmetic, System.Numerics.BigInteger) -
    higher digits/sec is faster:
      - Single-core: one thread, calculating in a loop for the full duration,
        total digits produced divided by elapsed seconds.
      - Multi-core: the same per-thread loop run in parallel across every
        logical processor, each for the same fixed duration; every worker's
        digit count is summed and divided by elapsed seconds. This is
        deliberately an aggregate-throughput measure, not an aggregate-latency
        one - see Measure-PiDigitsMultiCoreThroughput below for why.

    Deliberately NOT a cryptographic hash (SHA-256 in an earlier version of
    this script): mainstream CPUs since roughly 2019 (Ice Lake mobile onward on
    Intel, Zen onward on AMD) have hardware SHA acceleration (SHA-NI), while
    the fleet's many pre-2019 Skylake-generation machines do not. That made the
    old benchmark measure "does this CPU have a crypto accelerator" nearly as
    much as "is this CPU fast", which skews exactly the comparison this
    benchmark exists to make. Pi-digit calculation is pure arbitrary-precision
    arithmetic with no dedicated instruction-set fast path on any consumer
    CPU - only generic ALU/FPU throughput, which every x86 CPU since the
    386/487 era has had in some form, so it stays a genuine general-compute
    comparison across CPU generations. Methodology (fixed-duration,
    aggregate-throughput scoring) follows Crazegi/Pi-Bench-Tool
    (https://github.com/Crazegi/Pi-Bench-Tool), reimplemented here in
    PowerShell rather than reusing its Python code.

    Neither score is a portable/absolute benchmark - both are relative fleet-
    ranking signals only, not comparable to results from other tools.

    Posts the device ID and both measured throughput values to a narrow
    endpoint (`/api/inventory/benchmark`) that updates exactly those columns on
    the device's existing inventory row. Deliberately not the same endpoint
    Get-DeviceInventory.ps1 uses - that one's UPDATE spans every column in its
    payload, so a small benchmark-only POST through it would null out every
    other field this script does not collect. The endpoint keeps only the
    highest score ever reported per device (a server-side ratchet, not
    something this script needs to know about) - a run that happens to compete
    with someone actively using the machine can only score the same or lower
    than a genuinely uncontended run, so it can never corrupt a good reading,
    only fail to beat it.

.NOTES
    Deployed to disk by the PSADT Win32 app alongside Get-DeviceInventory.ps1;
    invoked by the "Organization - CPU Benchmark" and "Organization - CPU
    Benchmark (Weekly Forced)" scheduled tasks. Harmless to run
    manually/interactively for testing - it only measures local CPU throughput
    and posts a two-field report. A manual run pegs every logical processor for
    -DurationSeconds seconds during the multi-core phase, so expect the machine
    to be briefly sluggish while it's running.
#>
[CmdletBinding()]
param (
    [String]$ConfigPath,
    [String]$LogPath = (Join-Path $env:ProgramData 'Organization\DeviceInventory\Logs\Invoke-CpuBenchmark.log'),
    [int]$DurationSeconds = 120
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

function Measure-PiDigitsThroughput {
    <#
    .SYNOPSIS
        Single-threaded, fixed-DURATION pi-digit calculation throughput benchmark:
        computes digits of pi via the Rabinowitz-Wagon streaming spigot algorithm
        (arbitrary-precision integer arithmetic, no dedicated CPU instruction-set
        fast path) for the full duration and reports digits/sec - higher is
        faster. Fixed duration rather than fixed digit count, deliberately: a
        short run mostly measures whatever boost clock the CPU can sustain for a
        couple of seconds, not the throughput it can actually sustain, and the
        per-digit cost grows as the working numbers get larger, so a fixed count
        would not be directly comparable across CPUs anyway.
    .PARAMETER DurationSeconds
        How long to calculate for.
    .OUTPUTS
        [Double] pi digits calculated per second - higher is faster.
    #>
    param([Parameter(Mandatory)][int]$DurationSeconds)

    Add-Type -AssemblyName System.Numerics -ErrorAction SilentlyContinue

    [System.Numerics.BigInteger]$q = 1
    [System.Numerics.BigInteger]$r = 0
    [System.Numerics.BigInteger]$t = 1
    [System.Numerics.BigInteger]$k = 1
    [System.Numerics.BigInteger]$n = 3
    [System.Numerics.BigInteger]$l = 3
    $digitsCalculated = 0L

    $limit = [TimeSpan]::FromSeconds($DurationSeconds)
    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    while ($stopwatch.Elapsed -lt $limit) {
        if (($q * 4 + $r - $t) -lt ($n * $t)) {
            $digitsCalculated++
            $nr = ($r - $n * $t) * 10
            $n = ((($q * 3 + $r) * 10) / $t) - $n * 10
            $q *= 10
            $r = $nr
        } else {
            $nr = ($q * 2 + $r) * $l
            $nn = ($q * ($k * 7 + 2) + $r * $l) / ($t * $l)
            $q *= $k
            $t *= $l
            $l += 2
            $k += 1
            $n = $nn
            $r = $nr
        }
    }
    $stopwatch.Stop()
    return $digitsCalculated / $stopwatch.Elapsed.TotalSeconds
}

function Measure-PiDigitsMultiCoreThroughput {
    <#
    .SYNOPSIS
        Same fixed-duration pi-digit calculation as Measure-PiDigitsThroughput, run
        N-way in parallel (N = logical processor count) via a runspace pool for the
        same fixed duration - each worker maintains its own independent spigot
        state, so there's no shared state or synchronization between threads to
        skew the timing. Every worker's digit count is summed and divided by the
        overall elapsed time, giving an aggregate throughput figure: this rewards
        more cores contributing more total work over the shared window, rather
        than rewarding whichever configuration finishes a fixed amount of work
        soonest (which would favor a few very fast cores over many slower ones,
        even when the many-slower-core machine is clearly doing more total work
        per second).

        A runspace pool rather than PowerShell 7's `ForEach-Object -Parallel`
        because this targets Windows PowerShell 5.1 (same constraint as the rest of
        this app), and rather than passing a scriptblock to a .NET
        [Threading.Tasks.Parallel] delegate because scriptblock-to-delegate capture
        of outer-scope variables across threads is a known PowerShell footgun -
        explicit -AddArgument to each worker's own script instance sidesteps it
        entirely.
    .PARAMETER DurationSeconds
        How long each worker calculates for.
    .OUTPUTS
        [Double] aggregate pi digits calculated per second across every logical
        processor - higher is faster/more capable.
    #>
    param([Parameter(Mandatory)][int]$DurationSeconds)

    $processorCount = [Math]::Max(1, [Environment]::ProcessorCount)

    $workerScript = {
        param($DurationSeconds)
        Add-Type -AssemblyName System.Numerics -ErrorAction SilentlyContinue
        [System.Numerics.BigInteger]$q = 1
        [System.Numerics.BigInteger]$r = 0
        [System.Numerics.BigInteger]$t = 1
        [System.Numerics.BigInteger]$k = 1
        [System.Numerics.BigInteger]$n = 3
        [System.Numerics.BigInteger]$l = 3
        $digitsCalculated = 0L
        $limit = [TimeSpan]::FromSeconds($DurationSeconds)
        $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
        while ($stopwatch.Elapsed -lt $limit) {
            if (($q * 4 + $r - $t) -lt ($n * $t)) {
                $digitsCalculated++
                $nr = ($r - $n * $t) * 10
                $n = ((($q * 3 + $r) * 10) / $t) - $n * 10
                $q *= 10
                $r = $nr
            } else {
                $nr = ($q * 2 + $r) * $l
                $nn = ($q * ($k * 7 + 2) + $r * $l) / ($t * $l)
                $q *= $k
                $t *= $l
                $l += 2
                $k += 1
                $n = $nn
                $r = $nr
            }
        }
        return $digitsCalculated
    }

    $pool = [runspacefactory]::CreateRunspacePool(1, $processorCount)
    $pool.Open()
    $workers = @()
    try {
        $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
        for ($i = 0; $i -lt $processorCount; $i++) {
            $shell = [powershell]::Create()
            $shell.RunspacePool = $pool
            [void]$shell.AddScript($workerScript).AddArgument($DurationSeconds)
            $workers += [pscustomobject]@{ Shell = $shell; Handle = $shell.BeginInvoke() }
        }
        $totalDigits = 0L
        foreach ($worker in $workers) {
            $totalDigits += ($worker.Shell.EndInvoke($worker.Handle))[0]
        }
        $stopwatch.Stop()
    } finally {
        foreach ($worker in $workers) { $worker.Shell.Dispose() }
        $pool.Close()
        $pool.Dispose()
    }
    return $totalDigits / $stopwatch.Elapsed.TotalSeconds
}

#region Main
Write-BenchmarkLog -Message "Starting CPU benchmark run (DurationSeconds=$DurationSeconds per phase)."

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

$singleCoreScore = [Math]::Round((Measure-PiDigitsThroughput -DurationSeconds $DurationSeconds), 2)
Write-BenchmarkLog -Message "Single-core benchmark complete: $singleCoreScore pi digits/sec."

$multiCoreScore = [Math]::Round((Measure-PiDigitsMultiCoreThroughput -DurationSeconds $DurationSeconds), 2)
Write-BenchmarkLog -Message "Multi-core benchmark complete ($([Environment]::ProcessorCount) logical processors): $multiCoreScore pi digits/sec aggregate."

$payload = [pscustomobject]@{
    azureAdDeviceId       = $azureAdDeviceId
    cpuBenchmarkScore      = $singleCoreScore
    cpuBenchmarkMultiCoreScore = $multiCoreScore
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
