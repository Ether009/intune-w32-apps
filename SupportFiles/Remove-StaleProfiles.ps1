#Requires -Version 5.1
<#
.SYNOPSIS
    Deletes stale local user profiles that have not been used within a configured
    number of days, while protecting the device's most recent users.

.DESCRIPTION
    Runs as NT AUTHORITY\SYSTEM from a scheduled task on a daily trigger. Enumerates
    Win32_UserProfile (excluding Special/built-in profiles - SYSTEM, LocalService,
    NetworkService, Default, Public, defaultuser0, etc., which Windows itself flags),
    and for each remaining profile decides whether to delete it based on LastUseTime
    versus RetentionDays from the JSON config - unless the profile is protected:

      - One of the ProtectedRecentUsers (default 2) most recently used profiles. This
        is also what protects whoever is signed in right now: LastUseTime keeps
        advancing throughout an active session, so an active user always sorts first.
        No separate "is anyone logged on" check is therefore needed.
      - Listed by SID or account name in the config's exclusion lists.

    Everyone outside that set can be acted on forcefully when needed - signed out
    (Invoke-ForceLogoff) and had their registry hive unloaded
    (Dismount-UserProfileHive) so the profile can actually be removed. A loaded hive
    is something to clear out of the way, not a reason to keep a stale profile.

    Deletion uses Remove-CimInstance (not a raw folder delete), so NTUSER.DAT
    unloading, registry hive cleanup, and ACLs are handled the same way Windows' own
    "Delete Account" UI does it; the escalation above only runs if that first attempt
    fails.

    If LogOnly is true in the config (the shipped default), every deletion decision is
    logged as "Would delete" but nothing is actually removed - flip it to false once
    the logged candidates have been reviewed across the fleet.

    Optionally (Dehydrate, off by default - prototype), a stale profile that ends up
    NOT deleted this run for any reason - kept/protected, a LogOnly candidate, or a
    failed delete attempt - can have every OneDrive-managed folder under it (personal/
    business OneDrive, and any synced SharePoint document library, wherever it's
    nested) "unpinned" to reclaim disk space without touching the profile itself. See
    Invoke-OneDriveDehydration below and the README's safety note.

    Independent of all of the above, every run also handles each profile's Downloads
    folder one of two ways:
      - For the small, explicitly configured set of shared/generic accounts in
        DownloadsPurgeUsernames/DownloadsPurgeUpns, Downloads is unconditionally
        emptied every run regardless of staleness/LogOnly - see Clear-DownloadsFolder.
        If a file is locked because that account happens to be logged on, the session
        is force-logged-off (Invoke-ForceLogoff) and deletion is retried.
      - For every other profile (when ScanDownloads is on, the default), Downloads is
        scanned read-only for filename/size/last-accessed/last-written per file, and
        the result is currently discarded - see Get-DownloadsInventory.

.NOTES
    Deployed to disk by the PSADT Win32 app; invoked by the "Cleanup Stale User
    Profiles" scheduled task. Not intended to be run manually as a normal user.
#>
[CmdletBinding()]
param (
    [String]$ConfigPath,
    [String]$LogPath = (Join-Path $env:ProgramData 'Organization\ProfileCleanup\Logs\Remove-StaleProfiles.log')
)

# Resolved here, not in param(): $PSScriptRoot is empty while parameter defaults are
# evaluated under powershell.exe -File.
if ([string]::IsNullOrWhiteSpace($ConfigPath)) { $ConfigPath = Join-Path $PSScriptRoot 'ProfileCleanupConfig.json' }

$ErrorActionPreference = 'Stop'

#region Logging
function Write-CleanupLog {
    <#
    .SYNOPSIS
        Appends one line to the run's log file, rotating it if it has grown past 2MB.
        Never throws - logging must not be able to break the cleanup run.
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
        # Logging must never break the cleanup run.
    }
}
#endregion

#region Config
function Get-DefaultCleanupConfig {
    <#
    .SYNOPSIS
        Returns the built-in default config values, used whenever the config file is
        missing or fails to parse.
    .OUTPUTS
        [pscustomobject] every config field set to its default value.
    #>
    [pscustomobject]@{
        Version                    = ''
        RetentionDays              = 30
        LogOnly                    = $true
        ExcludedSids               = @()
        ExcludedUsernames          = @()
        NotificationWebhookUrl     = ''
        NotifyOnlyIfActionable     = $false
        IncludeProfileSize         = $true
        TopFolderCount             = 10
        TopFolderMinMB             = 0
        Dehydrate                  = $false
        ClearBrowserCaches         = $false
        BrowserCachePaths          = @(
            'AppData\Local\Microsoft\Edge\User Data\*\Cache'
            'AppData\Local\Microsoft\Edge\User Data\*\Code Cache'
            'AppData\Local\Microsoft\Edge\User Data\*\GPUCache'
            'AppData\Local\Google\Chrome\User Data\*\Cache'
            'AppData\Local\Google\Chrome\User Data\*\Code Cache'
            'AppData\Local\Google\Chrome\User Data\*\GPUCache'
            'AppData\Local\Mozilla\Firefox\Profiles\*\cache2'
        )
        RedirectFolders            = @()
        AdditionalDehydrateFolders = @()
        DownloadsPurgeUsernames    = @()
        DownloadsPurgeUpns         = @()
        ScanDownloads              = $true
        ProtectedRecentUsers       = 2
        # Local-only folders that nothing but the user themselves writes to.
        # Deliberately excludes:
        #   Temp / Packages - Storage Sense, cleanup tools and Store servicing write
        #                     these for every profile on the device.
        #   Desktop / Documents / Downloads - OneDrive Known Folder Move syncs these,
        #                     so a change made on any device updates them everywhere.
        #                     Observed live: two machines reported the same profile's
        #                     Downloads with an identical timestamp to the minute.
        ActivityPaths              = @(
            'AppData\Roaming\Microsoft\Windows\Recent'
            'AppData\Local\Microsoft\Edge\User Data\Default'
            'AppData\Local\Google\Chrome\User Data\Default'
        )
    }
}

function Read-CleanupConfigFile {
    <#
    .SYNOPSIS
        Reads and parses the JSON config file. Logs the specific reason and returns
        $null (rather than throwing) if the file is missing or invalid.
    .PARAMETER Path
        Full path to the JSON config file.
    .OUTPUTS
        The parsed JSON object, or $null on failure.
    #>
    param([Parameter(Mandatory)][String]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        Write-CleanupLog -Severity Warning -Message "Config file not found at '$Path'; using built-in defaults (RetentionDays=30, LogOnly=true)."
        return $null
    }
    try {
        # Read as UTF-8 explicitly - Windows PowerShell 5.1's default Get-Content
        # encoding is ANSI.
        return Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json
    } catch {
        Write-CleanupLog -Severity Error -Message "Failed to parse config file '$Path': $_. Using built-in defaults (RetentionDays=30, LogOnly=true)."
        return $null
    }
}

function ConvertTo-CleanupConfig {
    <#
    .SYNOPSIS
        Coerces a raw parsed JSON config object into a fully-typed config object,
        filling in any missing/null field from the supplied defaults.
    .PARAMETER Raw
        The parsed JSON object, from Read-CleanupConfigFile.
    .PARAMETER Defaults
        The default values object, from Get-DefaultCleanupConfig.
    .OUTPUTS
        [pscustomobject] every config field present and correctly typed.
    #>
    param(
        [Parameter(Mandatory)][Object]$Raw,
        [Parameter(Mandatory)][Object]$Defaults
    )
    [pscustomobject]@{
        Version                    = if ($null -ne $Raw.Version) { [string]$Raw.Version } else { $Defaults.Version }
        RetentionDays              = if ($null -ne $Raw.RetentionDays) { [int]$Raw.RetentionDays } else { $Defaults.RetentionDays }
        LogOnly                    = if ($null -ne $Raw.LogOnly) { [bool]$Raw.LogOnly } else { $Defaults.LogOnly }
        ExcludedSids               = @($Raw.ExcludedSids | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
        ExcludedUsernames          = @($Raw.ExcludedUsernames | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
        NotificationWebhookUrl     = if ($null -ne $Raw.NotificationWebhookUrl) { [string]$Raw.NotificationWebhookUrl } else { $Defaults.NotificationWebhookUrl }
        NotifyOnlyIfActionable     = if ($null -ne $Raw.NotifyOnlyIfActionable) { [bool]$Raw.NotifyOnlyIfActionable } else { $Defaults.NotifyOnlyIfActionable }
        IncludeProfileSize         = if ($null -ne $Raw.IncludeProfileSize) { [bool]$Raw.IncludeProfileSize } else { $Defaults.IncludeProfileSize }
        TopFolderCount             = if ($null -ne $Raw.TopFolderCount) { [int]$Raw.TopFolderCount } else { $Defaults.TopFolderCount }
        TopFolderMinMB             = if ($null -ne $Raw.TopFolderMinMB) { [int]$Raw.TopFolderMinMB } else { $Defaults.TopFolderMinMB }
        Dehydrate                  = if ($null -ne $Raw.Dehydrate) { [bool]$Raw.Dehydrate } else { $Defaults.Dehydrate }
        ClearBrowserCaches         = if ($null -ne $Raw.ClearBrowserCaches) { [bool]$Raw.ClearBrowserCaches } else { $Defaults.ClearBrowserCaches }
        BrowserCachePaths          = if ($null -ne $Raw.BrowserCachePaths) { @($Raw.BrowserCachePaths | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }) } else { $Defaults.BrowserCachePaths }
        RedirectFolders            = @($Raw.RedirectFolders | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
        AdditionalDehydrateFolders = @($Raw.AdditionalDehydrateFolders | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
        DownloadsPurgeUsernames    = @($Raw.DownloadsPurgeUsernames | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
        DownloadsPurgeUpns         = @($Raw.DownloadsPurgeUpns | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
        ScanDownloads              = if ($null -ne $Raw.ScanDownloads) { [bool]$Raw.ScanDownloads } else { $Defaults.ScanDownloads }
        ProtectedRecentUsers       = if ($null -ne $Raw.ProtectedRecentUsers) { [int]$Raw.ProtectedRecentUsers } else { $Defaults.ProtectedRecentUsers }
        ActivityPaths              = if ($Raw.ActivityPaths) { @($Raw.ActivityPaths | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }) } else { $Defaults.ActivityPaths }
    }
}

function Get-CleanupConfig {
    <#
    .SYNOPSIS
        Loads the effective config: reads and parses the JSON file, falling back to
        built-in defaults if it's missing or invalid.
    .PARAMETER Path
        Full path to the JSON config file.
    .OUTPUTS
        [pscustomobject] the fully-typed config, ready to use.
    #>
    param([Parameter(Mandatory)][String]$Path)

    $defaults = Get-DefaultCleanupConfig
    $raw = Read-CleanupConfigFile -Path $Path
    if ($null -eq $raw) { return $defaults }
    return ConvertTo-CleanupConfig -Raw $raw -Defaults $defaults
}
#endregion

#region Account identity resolution
function Test-IsRealUserSid {
    <#
    .SYNOPSIS
        Checks whether a SID identifies a real interactive user account rather than a
        built-in service/virtual identity (SYSTEM S-1-5-18, LOCAL SERVICE S-1-5-19,
        NETWORK SERVICE S-1-5-20, virtual-account SIDs S-1-5-90-*, etc.). Used to
        reject a lookup that accidentally landed on a service identity.
    .PARAMETER Sid
        The SID string to check.
    .OUTPUTS
        [bool] $true if it looks like a real user account SID.
    #>
    param([String]$Sid)
    if ([string]::IsNullOrWhiteSpace($Sid)) { return $false }
    # Azure AD user SIDs are S-1-12-1-*; local/domain users are S-1-5-21-*.
    if ($Sid -match '^S-1-12-1-\d') { return $true }
    if ($Sid -match '^S-1-5-21-\d') { return $true }
    return $false
}

function Resolve-UpnViaNTAccount {
    <#
    .SYNOPSIS
        Tries to resolve a UPN to a local SID via a direct NTAccount translation -
        works for hybrid Azure AD-joined domain accounts with line of sight to a DC.
    .PARAMETER Upn
        The UPN to resolve.
    .OUTPUTS
        The SID string, or $null if it could not be resolved this way.
    #>
    param([Parameter(Mandatory)][String]$Upn)
    try {
        $sid = (New-Object System.Security.Principal.NTAccount($Upn)).Translate([System.Security.Principal.SecurityIdentifier]).Value
        if ($sid) { return $sid }
    } catch {
        # Expected for pure Azure AD-joined devices/accounts - the caller falls back
        # to the identity cache.
    }
    return $null
}

function Resolve-UpnViaIdentityCache {
    <#
    .SYNOPSIS
        Tries to resolve a UPN to a local SID via the Azure AD identity store cache
        (HKLM\SOFTWARE\Microsoft\IdentityStore\Cache) - works for pure Azure AD-joined
        devices, for any account that has actually signed in on this device. Reads the
        *leaf* key (the user's SID), not the outer key, and validates it with
        Test-IsRealUserSid.
    .PARAMETER Upn
        The UPN to resolve.
    .OUTPUTS
        The user's SID string, or $null if no cached mapping matches.
    #>
    param([Parameter(Mandatory)][String]$Upn)

    $cacheRoot = 'HKLM:\SOFTWARE\Microsoft\IdentityStore\Cache'
    if (-not (Test-Path -LiteralPath $cacheRoot)) { return $null }

    foreach ($sidKey in Get-ChildItem -LiteralPath $cacheRoot -ErrorAction SilentlyContinue) {
        $identityCachePath = Join-Path $sidKey.PSPath 'IdentityCache'
        if (-not (Test-Path -LiteralPath $identityCachePath)) { continue }
        foreach ($leaf in Get-ChildItem -LiteralPath $identityCachePath -ErrorAction SilentlyContinue) {
            try {
                $props = Get-ItemProperty -LiteralPath $leaf.PSPath -ErrorAction Stop
                if ($props.UserName -and ($props.UserName -ieq $Upn) -and (Test-IsRealUserSid -Sid $leaf.PSChildName)) {
                    return $leaf.PSChildName
                }
            } catch {
                continue
            }
        }
    }
    return $null
}

function Resolve-UpnToSid {
    <#
    .SYNOPSIS
        Resolves a UPN to a local SID: tries a direct NTAccount translation first
        (Resolve-UpnViaNTAccount), then falls back to the Azure AD identity store
        cache (Resolve-UpnViaIdentityCache).
    .PARAMETER Upn
        The UPN to resolve.
    .OUTPUTS
        The SID string, or $null if neither method found a mapping (e.g. the account
        has never signed in on this device).
    #>
    param([Parameter(Mandatory)][String]$Upn)
    $sid = Resolve-UpnViaNTAccount -Upn $Upn
    if ($sid) { return $sid }
    return Resolve-UpnViaIdentityCache -Upn $Upn
}
#endregion

#region Profile size
# Identifies a cloud placeholder - a OneDrive file stored "online-only", which reports
# its full logical size while occupying essentially nothing on this disk. Those bytes
# are excluded from every size this script reports, because counting them badly
# overstates what deleting a profile would reclaim: measured on a real profile, two
# synced folders were inflated by 71% and 96%.
#
# FILE_ATTRIBUTE_OFFLINE (0x1000) and FILE_ATTRIBUTE_RECALL_ON_DATA_ACCESS (0x400000)
# are the pair Windows sets on such a file; either one is enough to identify it.
# Verified against real files: a placeholder reads 0x401620, while locally-present
# files read 0x420 and 0x180026.
#
# Kept as a value rather than a function deliberately. Get-ProfileSizeBreakdown tests
# it once per file, and a function call at that rate cost 14 seconds on a
# 258,830-file profile.
$script:CloudPlaceholderAttributeMask = 0x1000 -bor 0x400000

function Get-ProfileFolderKey {
    <#
    .SYNOPSIS
        Works out which folder a file counts towards, as the first few levels of its
        path below the profile root. Files deeper than that roll up into their
        ancestor at this depth, which bounds how many folders are tracked: a profile
        can hold hundreds of thousands of directories, but only a few thousand down
        to this level.
    .PARAMETER DirectoryPath
        The full path of the folder the file sits in.
    .PARAMETER ProfileRoot
        The profile folder, with a trailing backslash.
    .PARAMETER Depth
        How many path levels to keep.
    .OUTPUTS
        [String] the folder label, or "(profile root)" for files directly in the
        profile folder.
    #>
    param(
        [Parameter(Mandatory)][String]$DirectoryPath,
        [Parameter(Mandatory)][String]$ProfileRoot,
        [Int32]$Depth = 2
    )
    if ($DirectoryPath.Length -le $ProfileRoot.Length) { return '(profile root)' }
    return (Get-TruncatedFolderKey -Key $DirectoryPath.Substring($ProfileRoot.Length) -Depth $Depth)
}

function Get-TruncatedFolderKey {
    <#
    .SYNOPSIS
        Shortens a folder path to its first N levels. Used both when collecting sizes
        and when deciding how much of each path to report.
    .PARAMETER Key
        A profile-relative folder path.
    .PARAMETER Depth
        How many levels to keep.
    .OUTPUTS
        [String] the shortened path, or the original if it is already shorter.
    #>
    param(
        [Parameter(Mandatory)][AllowEmptyString()][String]$Key,
        [Parameter(Mandatory)][Int32]$Depth
    )
    if ($Depth -lt 1) { return $Key }
    $parts = $Key.Split('\')
    if ($parts.Count -le $Depth) { return $Key }
    return ($parts[0..($Depth - 1)] -join '\')
}

function Get-BranchReportDepth {
    <#
    .SYNOPSIS
        Chooses how deep to report one branch of the profile, based on how much of
        the profile it holds. A branch holding most of the disk gets broken down
        further, because "AppData\Local - 29.2 GB" doesn't say which application is
        responsible; a small branch stays as a single line, because splitting it
        would spend several lines on something that doesn't matter.
    .PARAMETER BranchBytes
        The branch's total size.
    .PARAMETER TotalBytes
        The whole profile's size.
    .OUTPUTS
        [Int32] the number of path levels to report for this branch.
    #>
    param(
        [Parameter(Mandatory)][Int64]$BranchBytes,
        [Parameter(Mandatory)][Int64]$TotalBytes
    )
    if ($TotalBytes -le 0) { return 2 }
    $share = $BranchBytes / $TotalBytes
    if ($share -ge 0.20) { return 4 }
    if ($share -ge 0.08) { return 3 }
    return 2
}

function Get-AdaptiveFolderTotals {
    <#
    .SYNOPSIS
        Re-groups a collected breakdown so that large branches are reported in more
        detail than small ones. Works entirely from the already-collected figures -
        no second pass over the disk - by first measuring each branch at the base
        depth, then re-keying every entry at the depth that branch earned.

        Totals are preserved: every byte lands in exactly one output key, and files
        sitting directly in a shallow folder keep their own shorter key rather than
        being lost when deeper siblings are reported.
    .PARAMETER Folders
        The Folders hashtable from Get-ProfileSizeBreakdown.
    .PARAMETER TotalBytes
        The profile's total size, used to judge each branch's share.
    .OUTPUTS
        [hashtable] folder label -> bytes, at mixed depths.
    #>
    param(
        $Folders,
        [Parameter(Mandatory)][Int64]$TotalBytes
    )
    if ($null -eq $Folders -or $Folders.Count -eq 0) { return @{} }

    $branchTotals = @{}
    foreach ($entry in $Folders.GetEnumerator()) {
        $branch = Get-TruncatedFolderKey -Key $entry.Key -Depth 2
        if (-not $branchTotals.ContainsKey($branch)) { $branchTotals[$branch] = [int64]0 }
        $branchTotals[$branch] += $entry.Value
    }

    $result = @{}
    foreach ($entry in $Folders.GetEnumerator()) {
        $branch = Get-TruncatedFolderKey -Key $entry.Key -Depth 2
        $depth = Get-BranchReportDepth -BranchBytes $branchTotals[$branch] -TotalBytes $TotalBytes
        $key = Get-TruncatedFolderKey -Key $entry.Key -Depth $depth
        if (-not $result.ContainsKey($key)) { $result[$key] = [int64]0 }
        $result[$key] += $entry.Value
    }
    return $result
}

function Format-FolderSize {
    <#
    .SYNOPSIS
        Formats a byte count as a short size label for the folder breakdown, in GB
        past a gigabyte and MB below it. Invariant formatting, so the text reads
        "29.2 GB" rather than "29,2 GB" on this fleet's Swedish locale and matches
        the numeric fields alongside it.
    .PARAMETER Bytes
        The size in bytes.
    .OUTPUTS
        [String] e.g. "29.2 GB" or "512 MB".
    #>
    param([Parameter(Mandatory)][Int64]$Bytes)
    if ($Bytes -ge 1GB) {
        return [String]::Format([Globalization.CultureInfo]::InvariantCulture, '{0:0.0} GB', ($Bytes / 1GB))
    }
    return [String]::Format([Globalization.CultureInfo]::InvariantCulture, '{0:0} MB', ($Bytes / 1MB))
}

function Get-ProfileSizeBreakdown {
    <#
    .SYNOPSIS
        Walks a profile once and returns both its on-disk total and a per-folder
        breakdown. Both come from the same pass because the walk itself is the
        expensive part - measured on a 258,776-file profile, enumeration took 63s
        while totalling and grouping together took 7s, less than the pipeline-based
        sum it replaces.

        Counts only bytes really on this disk: cloud placeholders are skipped, since
        they report their full logical size while occupying nothing locally.

        Individual inaccessible files (rare - SYSTEM has broad access, but EFS-encrypted
        files or an explicit deny ACE can still block a read) are silently skipped
        rather than failing the whole calculation, so the total can undercount but this
        never throws.
    .PARAMETER Path
        Folder to measure.
    .PARAMETER MaxKeyDepth
        How many path levels to track. Collected deeper than it is reported, so
        Get-AdaptiveFolderTotals can drill into the branches that turn out to be
        large without the disk being walked twice.
    .OUTPUTS
        [pscustomobject] { TotalBytes ([int64]); Folders ([hashtable] label -> bytes) },
        or $null if Path doesn't exist or the scan failed.
    #>
    param(
        [Parameter(Mandatory)][String]$Path,
        [Int32]$MaxKeyDepth = 4
    )
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    try {
        $root = $Path.TrimEnd('\') + '\'
        $folders = @{}
        $total = [int64]0
        # Files far outnumber the folders holding them - 258,776 against roughly 50,000
        # on a real profile - so the label is worked out once per folder and reused.
        # Without this, deriving it per file made the scan 75% slower.
        $keyCache = @{}
        foreach ($file in (Get-ChildItem -LiteralPath $Path -Recurse -Force -File -ErrorAction SilentlyContinue)) {
            if ([int]$file.Attributes -band $script:CloudPlaceholderAttributeMask) { continue }
            $total += $file.Length
            $directory = $file.DirectoryName
            $key = $keyCache[$directory]
            if ($null -eq $key) {
                $key = Get-ProfileFolderKey -DirectoryPath $directory -ProfileRoot $root -Depth $MaxKeyDepth
                $keyCache[$directory] = $key
            }
            if (-not $folders.ContainsKey($key)) { $folders[$key] = [int64]0 }
            $folders[$key] += $file.Length
        }
        return [pscustomobject]@{ TotalBytes = $total; Folders = $folders }
    } catch {
        return $null
    }
}

function Get-DehydratableBytes {
    <#
    .SYNOPSIS
        How much of a profile dehydration could still release: the bytes physically
        present inside its OneDrive-synced folders. Anything already online-only was
        left out of the breakdown in the first place, so what remains here is exactly
        what "Free up space" would reclaim.

        Read out of the breakdown already in memory rather than by measuring those
        folders again, so knowing the figure costs nothing beyond the size scan that
        has already happened.
    .PARAMETER Folders
        The Folders hashtable from Get-ProfileSizeBreakdown.
    .PARAMETER ProfilePath
        The profile root, used to turn sync folder paths into the relative form the
        breakdown is keyed by.
    .PARAMETER SyncFolders
        The profile's OneDrive-synced folders (see Get-OneDriveSyncFolders).
    .OUTPUTS
        [int64] bytes that dehydration could release. A synced folder nested deeper
        than the breakdown is keyed will not be found and so is not counted, which
        understates rather than overstates the figure.
    #>
    param(
        $Folders,
        [Parameter(Mandatory)][String]$ProfilePath,
        [Object[]]$SyncFolders = @()
    )
    if ($null -eq $Folders -or $Folders.Count -eq 0 -or $SyncFolders.Count -eq 0) { return [int64]0 }
    $root = $ProfilePath.TrimEnd('\') + '\'
    $total = [int64]0
    foreach ($entry in $Folders.GetEnumerator()) {
        foreach ($syncFolder in $SyncFolders) {
            if ($syncFolder.FullName.Length -le $root.Length) { continue }
            $relative = $syncFolder.FullName.Substring($root.Length)
            if ($entry.Key -eq $relative -or $entry.Key.StartsWith("$relative\")) {
                $total += $entry.Value
                break
            }
        }
    }
    return $total
}

function Format-TopFolders {
    <#
    .SYNOPSIS
        Renders the largest folders from a breakdown as one line each, newest-largest
        first. Returned as a single string rather than a list because the receiving
        flow places it in one text block - Power Automate cannot easily nest a
        per-profile list inside a per-profile row.
    .PARAMETER Folders
        The Folders hashtable from Get-ProfileSizeBreakdown.
    .PARAMETER Count
        How many folders to list.
    .OUTPUTS
        [String] one "- folder - size" line per folder, newline separated; empty
        string when there is nothing to report. Written as a Markdown bullet list
        because a Teams card renders a bare newline inconsistently, while it renders
        a bullet list reliably - and the dashes still read fine in the raw report.
    #>
    param(
        $Folders,
        [Int32]$Count = 10
    )
    if ($null -eq $Folders -or $Folders.Count -eq 0 -or $Count -lt 1) { return '' }
    # Anything under a megabyte is dropped rather than allowed to fill a slot: a
    # profile with few folders was listing entries that rounded to "0 MB", which
    # crowds out nothing useful but reads as noise.
    $top = $Folders.GetEnumerator() |
        Where-Object { $_.Value -ge 1MB } |
        Sort-Object -Property Value -Descending |
        Select-Object -First $Count
    $lines = foreach ($entry in $top) {
        "- $($entry.Key) - $(Format-FolderSize -Bytes $entry.Value)"
    }
    return ($lines -join "`n")
}

function Get-ProfileSizeBytes {
    <#
    .SYNOPSIS
        On-disk size of a folder in bytes. Thin wrapper over
        Get-ProfileSizeBreakdown for the callers that only need the total.
    .PARAMETER Path
        Folder to measure.
    .OUTPUTS
        [int64] bytes actually on disk, or $null if Path doesn't exist or the scan failed.
    #>
    param([Parameter(Mandatory)][String]$Path)
    $breakdown = Get-ProfileSizeBreakdown -Path $Path
    if ($null -eq $breakdown) { return $null }
    return $breakdown.TotalBytes
}
#endregion

#region OneDrive dehydration (prototype)
function Test-OneDriveMarkerPresent {
    <#
    .SYNOPSIS
        Checks whether a folder contains OneDrive's internal marker file - the
        (undocumented, but consistently observed) signal that a folder is actively
        managed by the OneDrive sync client, personal/Business OneDrive or a synced
        SharePoint library alike. Not documented/guaranteed Microsoft behavior; see
        the README for the evidence behind it and the fallback if it ever changes.
    .PARAMETER FolderPath
        Full path to the folder to check.
    .OUTPUTS
        [bool] $true if the marker file is present.
    #>
    param([Parameter(Mandatory)][String]$FolderPath)
    $marker = '.849C9593-D756-4E56-8D6E-42412F2A707B'
    return [bool](Get-Item -LiteralPath (Join-Path $FolderPath $marker) -Force -ErrorAction SilentlyContinue)
}

function Find-OneDriveMarkerFolders {
    <#
    .SYNOPSIS
        Searches up to two levels below a profile root for folders carrying
        OneDrive's marker file (Test-OneDriveMarkerPresent) - catches the OneDrive
        root as well as SharePoint libraries synced under a site-derived name.
    .PARAMETER ProfilePath
        Full path to the profile root to search under.
    .OUTPUTS
        [System.IO.DirectoryInfo[]] every matching folder found.
    #>
    param([Parameter(Mandatory)][String]$ProfilePath)

    $found = New-Object System.Collections.Generic.List[System.IO.DirectoryInfo]
    $candidates = @(Get-ChildItem -LiteralPath $ProfilePath -Directory -Recurse -Depth 2 -Force -ErrorAction SilentlyContinue)
    foreach ($dir in $candidates) {
        if (Test-OneDriveMarkerPresent -FolderPath $dir.FullName) {
            $found.Add($dir)
        }
    }
    return $found.ToArray()
}

function Resolve-AdditionalDehydrateFolders {
    <#
    .SYNOPSIS
        Resolves the AdditionalDehydrateFolders config entries (paths relative to a
        profile root) to actual existing directories - the manual fallback for when
        marker-based detection (Find-OneDriveMarkerFolders) doesn't find a folder,
        e.g. if OneDrive's marker file ever silently changes.
    .PARAMETER ProfilePath
        Full path to the profile root the relative paths are relative to.
    .PARAMETER RelativePaths
        Folder paths relative to ProfilePath.
    .OUTPUTS
        [System.IO.DirectoryInfo[]] the relative paths that actually exist as folders.
    #>
    param(
        [Parameter(Mandatory)][String]$ProfilePath,
        [String[]]$RelativePaths = @()
    )

    $found = New-Object System.Collections.Generic.List[System.IO.DirectoryInfo]
    foreach ($relativePath in $RelativePaths) {
        if ([string]::IsNullOrWhiteSpace($relativePath)) { continue }
        $candidate = Get-Item -LiteralPath (Join-Path $ProfilePath $relativePath) -Force -ErrorAction SilentlyContinue
        if ($candidate -and $candidate.PSIsContainer) {
            $found.Add($candidate)
        }
    }
    return $found.ToArray()
}

function Get-OneDriveSyncFolders {
    <#
    .SYNOPSIS
        Finds every OneDrive-managed folder under a profile: automatic marker-file
        detection (Find-OneDriveMarkerFolders) plus any manually configured fallback
        paths (Resolve-AdditionalDehydrateFolders), deduplicated by full path.
    .PARAMETER ProfilePath
        Full path to the profile root.
    .PARAMETER AdditionalRelativePaths
        Extra folder paths (relative to ProfilePath) always treated as OneDrive-managed.
    .OUTPUTS
        [System.IO.DirectoryInfo[]] every matching folder, automatic + manual, deduped.
    #>
    param(
        [Parameter(Mandatory)][String]$ProfilePath,
        [String[]]$AdditionalRelativePaths = @()
    )

    $found = New-Object System.Collections.Generic.List[System.IO.DirectoryInfo]
    foreach ($dir in (Find-OneDriveMarkerFolders -ProfilePath $ProfilePath)) {
        $found.Add($dir)
    }
    foreach ($dir in (Resolve-AdditionalDehydrateFolders -ProfilePath $ProfilePath -RelativePaths $AdditionalRelativePaths)) {
        if (-not ($found | Where-Object { $_.FullName -ieq $dir.FullName })) {
            $found.Add($dir)
        }
    }
    return $found.ToArray()
}

function Invoke-AttribUnpin {
    <#
    .SYNOPSIS
        Recursively unpins one folder via attrib.exe (+U -P /S /D) - the same
        Pinned/Unpinned NTFS attribute Explorer's "Free up space" flips, causing the
        Cloud Filter driver to evict the local bytes of any OneDrive placeholder inside.
    .PARAMETER FolderPath
        Full path to the folder to unpin.
    .OUTPUTS
        [bool] $true if attrib.exe reported success (exit code 0).
    #>
    param([Parameter(Mandatory)][String]$FolderPath)
    try {
        & attrib.exe '+U' '-P' (Join-Path $FolderPath '*') /S /D
        return ($LASTEXITCODE -eq 0)
    } catch {
        return $false
    }
}

function Invoke-OneDriveDehydration {
    <#
    .SYNOPSIS
        PROTOTYPE. Unpins every OneDrive-managed folder under a profile
        (Get-OneDriveSyncFolders + Invoke-AttribUnpin) so the Cloud Filter driver can
        reclaim local disk space, without touching the profile itself.
    .PARAMETER ProfilePath
        Full path to the profile root.
    .PARAMETER AdditionalRelativePaths
        Extra folder paths (relative to ProfilePath) always treated as OneDrive-managed.
    .OUTPUTS
        [pscustomobject] { FoldersFound; Succeeded; Detail } summarizing the attempt.
    #>
    param(
        [Parameter(Mandatory)][String]$ProfilePath,
        [String[]]$AdditionalRelativePaths = @()
    )

    $result = [pscustomobject]@{
        FoldersFound = 0
        Succeeded    = $false
        Detail       = ''
    }

    $syncFolders = @(Get-OneDriveSyncFolders -ProfilePath $ProfilePath -AdditionalRelativePaths $AdditionalRelativePaths)
    $result.FoldersFound = $syncFolders.Count
    if ($syncFolders.Count -eq 0) {
        $result.Detail = 'no OneDrive-managed folder found'
        return $result
    }

    $folderLabels = ($syncFolders | ForEach-Object { $_.FullName.Substring($ProfilePath.Length).TrimStart('\') }) -join ', '
    $failures = 0
    foreach ($folder in $syncFolders) {
        if (-not (Invoke-AttribUnpin -FolderPath $folder.FullName)) { $failures++ }
    }
    $result.Succeeded = ($failures -eq 0)
    $result.Detail = "unpinned $($syncFolders.Count) OneDrive-managed folder(s): $folderLabels$(if ($failures -gt 0) { " ($failures with errors)" })"
    return $result
}

function Invoke-ProfileDehydrationIfEligible {
    <#
    .SYNOPSIS
        Central call site for the dehydration prototype - safe to call regardless of
        eligibility (returns an empty result immediately when not eligible), so every
        caller can do this the same way rather than duplicating the eligibility check.
        When a real attempt is made and IncludeProfileSize is on, re-measures the
        profile size afterward so the report shows what was actually reclaimed.
    .PARAMETER Profile
        The Win32_UserProfile CIM instance.
    .PARAMETER Config
        The effective config.
    .PARAMETER Eligible
        Whether this profile qualifies (see Test-DehydrationEligible).
    .PARAMETER Label
        The profile's bare account label, for logging.
    .OUTPUTS
        [pscustomobject] { Detail (string, empty if not eligible/applicable);
        SizeMBAfter (decimal, or $null when nothing was re-measured) }
    #>
    param(
        [Parameter(Mandatory)][Object]$Profile,
        [Parameter(Mandatory)][Object]$Config,
        [Parameter(Mandatory)][Bool]$Eligible,
        [Parameter(Mandatory)][String]$Label
    )
    $result = [pscustomobject]@{ Detail = ''; SizeMBAfter = $null }
    if (-not $Eligible -or -not $Profile.LocalPath) { return $result }

    $dehydration = Invoke-OneDriveDehydration -ProfilePath $Profile.LocalPath -AdditionalRelativePaths $Config.AdditionalDehydrateFolders
    $result.Detail = $dehydration.Detail

    # Only re-measure when something was actually unpinned; otherwise the caller reuses
    # the before figure, since a second full scan would cost as much as the first.
    if ($dehydration.FoldersFound -gt 0 -and $Config.IncludeProfileSize) {
        $afterBytes = Get-ProfileSizeBytes -Path $Profile.LocalPath
        if ($null -ne $afterBytes) {
            $result.SizeMBAfter = [Math]::Round($afterBytes / 1MB, 1)
            $result.Detail = "$($result.Detail) (profile size after: $($result.SizeMBAfter) MB)"
        }
    }

    if ($dehydration.FoldersFound -gt 0) {
        Write-CleanupLog -Message "OneDrive dehydration for '$Label': $($result.Detail)."
    }
    return $result
}
#endregion

#region Interactive session detection
function Get-ActiveSessionIds {
    <#
    .SYNOPSIS
        Returns the Windows session IDs that currently have at least one running
        process. A session with processes is in use no matter how long ago it began,
        so this holds true for a session that has been open for months.
    .OUTPUTS
        [Int32[]] the session IDs (session 0 is excluded - it is the service session).
    #>
    try {
        return @(Get-Process -ErrorAction Stop | Select-Object -ExpandProperty SessionId -Unique | Where-Object { $_ -gt 0 })
    } catch {
        Write-CleanupLog -Severity Warning -Message "Could not enumerate processes to find active sessions: $_"
        return @()
    }
}

function Get-SidSessionMap {
    <#
    .SYNOPSIS
        Maps SIDs to the Windows session IDs they signed into, read from each loaded
        hive's HKU\<SID>\Volatile Environment\<sessionId> subkeys. Keyed by SID and
        session number throughout, so no account name is ever parsed.
    .OUTPUTS
        Array of [pscustomobject] { Sid; SessionId }.
    #>
    $map = New-Object System.Collections.Generic.List[Object]
    foreach ($hive in (Get-ChildItem 'Registry::HKEY_USERS' -ErrorAction SilentlyContinue)) {
        $sid = $hive.PSChildName
        if (-not (Test-IsRealUserSid -Sid $sid)) { continue }
        foreach ($sub in (Get-ChildItem "Registry::HKEY_USERS\$sid\Volatile Environment" -ErrorAction SilentlyContinue)) {
            if ($sub.PSChildName -match '^\d+$') {
                $map.Add([pscustomobject]@{ Sid = $sid; SessionId = [int]$sub.PSChildName })
            }
        }
    }
    return $map.ToArray()
}

function Get-ExplorerOwnedSessions {
    <#
    .SYNOPSIS
        Maps SIDs to session IDs from the running explorer.exe processes. Used
        alongside Get-SidSessionMap so a session is still found if its hive has no
        Volatile Environment entry.
    .OUTPUTS
        Array of [pscustomobject] { Sid; SessionId }.
    #>
    $found = New-Object System.Collections.Generic.List[Object]
    try {
        $explorers = @(Get-CimInstance -ClassName Win32_Process -Filter "Name='explorer.exe'" -ErrorAction Stop)
    } catch {
        Write-CleanupLog -Severity Warning -Message "Could not enumerate explorer.exe processes: $_"
        return $found.ToArray()
    }
    foreach ($explorer in $explorers) {
        try {
            $sid = (Invoke-CimMethod -InputObject $explorer -MethodName GetOwnerSid -ErrorAction Stop).Sid
        } catch {
            continue
        }
        if (Test-IsRealUserSid -Sid $sid) {
            $found.Add([pscustomobject]@{ Sid = $sid; SessionId = $explorer.SessionId })
        }
    }
    return $found.ToArray()
}

function Get-InteractiveSessions {
    <#
    .SYNOPSIS
        Identifies which SIDs are signed in right now, and the session each one owns.

        A profile is in use if its session still has running processes
        (Get-ActiveSessionIds), which is true regardless of how long the session has
        been open and does not depend on any particular shell running. The SID for a
        session comes from the registry (Get-SidSessionMap), with explorer.exe owners
        (Get-ExplorerOwnedSessions) unioned in as a second source. A stale hive left
        loaded after sign-out is correctly excluded, because its session no longer has
        processes.
    .OUTPUTS
        Array of [pscustomobject] { Sid; SessionId }, deduplicated by SID; empty when
        nobody is signed in.
    #>
    $activeIds = Get-ActiveSessionIds
    $candidates = @(Get-SidSessionMap) + @(Get-ExplorerOwnedSessions)

    $sessions = New-Object System.Collections.Generic.List[Object]
    foreach ($candidate in $candidates) {
        if ($candidate.SessionId -notin $activeIds) { continue }
        if ($sessions | Where-Object { $_.Sid -ieq $candidate.Sid }) { continue }
        $sessions.Add($candidate)
    }
    return $sessions.ToArray()
}

function Test-SidHasInteractiveSession {
    <#
    .SYNOPSIS
        Checks whether a SID currently owns an interactive session on this device.
    .PARAMETER Sid
        The SID to check.
    .PARAMETER Sessions
        The session list from Get-InteractiveSessions.
    .OUTPUTS
        [bool]
    #>
    param(
        [Parameter(Mandatory)][String]$Sid,
        [Object[]]$Sessions = @()
    )
    return [bool]($Sessions | Where-Object { $_.Sid -ieq $Sid })
}

function Get-SessionIdForSid {
    <#
    .SYNOPSIS
        Looks up the Windows session ID owned by a SID, for passing to logoff.exe.
    .PARAMETER Sid
        The SID whose session ID is wanted.
    .PARAMETER Sessions
        The session list from Get-InteractiveSessions.
    .OUTPUTS
        The session ID, or $null if that SID owns no interactive session.
    #>
    param(
        [Parameter(Mandatory)][String]$Sid,
        [Object[]]$Sessions = @()
    )
    $match = $Sessions | Where-Object { $_.Sid -ieq $Sid } | Select-Object -First 1
    if ($match) { return $match.SessionId }
    return $null
}
#endregion

#region Downloads handling
function Invoke-ForceLogoff {
    <#
    .SYNOPSIS
        Force-logs-off the interactive session owned by a SID via logoff.exe, using
        the SID-to-session-ID map from Get-InteractiveSessions. Used only as a last
        resort when a Downloads file is locked by that user's own session - never
        called just because a profile happens to be loaded.
    .PARAMETER Sid
        The SID whose session should be logged off.
    .PARAMETER Label
        The account's display label, for logging only.
    .PARAMETER Sessions
        The session list from Get-InteractiveSessions.
    .OUTPUTS
        [bool] $true if logoff.exe was invoked successfully.
    #>
    param(
        [Parameter(Mandatory)][String]$Sid,
        [Parameter(Mandatory)][String]$Label,
        [Object[]]$Sessions = @()
    )

    $sessionId = Get-SessionIdForSid -Sid $Sid -Sessions $Sessions
    if ($null -eq $sessionId) {
        Write-CleanupLog -Severity Warning -Message "No interactive session found for '$Label' ($Sid); could not force-logoff."
        return $false
    }

    try {
        & logoff.exe $sessionId
        Write-CleanupLog -Message "Forced logoff of session $sessionId ('$Label') to release locked Downloads file(s)."
        return $true
    } catch {
        Write-CleanupLog -Severity Warning -Message "logoff.exe failed for session $sessionId ('$Label'): $_"
        return $false
    }
}

function Get-ItemSizeBytes {
    <#
    .SYNOPSIS
        On-disk size of one file or folder, folders measured recursively. Online-only
        OneDrive files are excluded on the same basis as everywhere else in this
        script: they report a size but deleting them frees nothing locally.
    .PARAMETER Item
        The file or folder to measure.
    .OUTPUTS
        [int64] bytes, or 0 if it could not be measured.
    #>
    param([Parameter(Mandatory)][System.IO.FileSystemInfo]$Item)
    try {
        if (-not $Item.PSIsContainer) {
            if ([int]$Item.Attributes -band $script:CloudPlaceholderAttributeMask) { return [int64]0 }
            return [int64]$Item.Length
        }
        $sum = [int64]0
        foreach ($file in (Get-ChildItem -LiteralPath $Item.FullName -Recurse -Force -File -ErrorAction SilentlyContinue)) {
            if ([int]$file.Attributes -band $script:CloudPlaceholderAttributeMask) { continue }
            $sum += $file.Length
        }
        return $sum
    } catch {
        return [int64]0
    }
}

function Remove-DownloadsItems {
    <#
    .SYNOPSIS
        Attempts to delete each given filesystem item (recursively, for folders).
    .PARAMETER Items
        The files/folders to delete.
    .OUTPUTS
        [System.IO.FileSystemInfo[]] the items that failed to delete.
    #>
    param([Object[]]$Items = @())

    $failed = New-Object System.Collections.Generic.List[System.IO.FileSystemInfo]
    foreach ($item in $Items) {
        try {
            Remove-Item -LiteralPath $item.FullName -Recurse -Force -ErrorAction Stop
        } catch {
            $failed.Add($item)
        }
    }
    return $failed.ToArray()
}

function Clear-DownloadsFolder {
    <#
    .SYNOPSIS
        Unconditionally empties a profile's Downloads folder (files and subfolders),
        every run, regardless of RetentionDays/LogOnly/staleness - intended only for
        the configured set of Downloads-purge target accounts. If deletion fails
        because a file is locked and the profile is loaded, force-logs-off that
        session (Invoke-ForceLogoff) and retries the failed items once.
    .PARAMETER Profile
        The Win32_UserProfile CIM instance.
    .PARAMETER Label
        The profile's bare account name, for logging.
    .PARAMETER Sessions
        The session list from Get-InteractiveSessions, used to find the session to
        force-logoff by SID if a file turns out to be locked.
    .PARAMETER IsUntouchable
        Whether this profile is the last or primary user. Deletion of unlocked files
        still happens either way; this only suppresses the force-logoff escalation,
        so an active user is never signed out mid-work to release a lock.
    .OUTPUTS
        [pscustomobject] { ItemsFound; BytesDeleted; ItemsDeleted; ItemsFailed; ForcedLogoff; Detail }
    #>
    param(
        [Parameter(Mandatory)][Object]$Profile,
        [Parameter(Mandatory)][String]$Label,
        [Object[]]$Sessions = @(),
        [Bool]$IsUntouchable = $false
    )

    $result = [pscustomobject]@{
        ItemsFound   = 0
        BytesDeleted = [int64]0
        ItemsDeleted = 0
        ItemsFailed  = 0
        ForcedLogoff = $false
        Detail       = ''
    }

    $scan = Get-DownloadsTopLevelItems -Profile $Profile
    if ($scan.Reason) {
        $result.Detail = $scan.Reason
        return $result
    }

    $items = $scan.Items
    $result.ItemsFound = $items.Count
    # Measured before deleting, since afterwards there is nothing left to measure.
    $sizeByPath = @{}
    foreach ($item in $items) { $sizeByPath[$item.FullName] = Get-ItemSizeBytes -Item $item }
    $failedItems = Remove-DownloadsItems -Items $items
    $escalation = Invoke-DownloadsLockEscalation -Profile $Profile -Label $Label -FailedItems $failedItems -Sessions $Sessions -IsUntouchable $IsUntouchable

    $result.ForcedLogoff = $escalation.ForcedLogoff
    $result.ItemsFailed = $escalation.FailedItems.Count
    $result.ItemsDeleted = $result.ItemsFound - $result.ItemsFailed
    # Only what actually went: a locked item still occupies its space.
    $stillThere = @($escalation.FailedItems | ForEach-Object { $_.FullName })
    foreach ($path in $sizeByPath.Keys) { if ($stillThere -notcontains $path) { $result.BytesDeleted += $sizeByPath[$path] } }
    $result.Detail = Get-DownloadsPurgeDetail -Found $result.ItemsFound -Deleted $result.ItemsDeleted -Failed $result.ItemsFailed -ForcedLogoff $result.ForcedLogoff

    $severity = if ($result.ItemsFailed -gt 0) { 'Warning' } else { 'Info' }
    Write-CleanupLog -Severity $severity -Message "Downloads cleanup for '$Label': $($result.Detail)."
    return $result
}

function Get-DownloadsTopLevelItems {
    <#
    .SYNOPSIS
        Enumerates the top-level entries in a profile's Downloads folder, or explains
        why there is nothing to purge.
    .PARAMETER Profile
        The Win32_UserProfile CIM instance.
    .OUTPUTS
        [pscustomobject] { Items; Reason } - Reason is empty when Items is usable, or
        the log-ready explanation when there is nothing to do.
    #>
    param([Parameter(Mandatory)][Object]$Profile)

    if (-not $Profile.LocalPath) {
        return [pscustomobject]@{ Items = @(); Reason = 'no LocalPath on profile record' }
    }
    $downloadsPath = Join-Path $Profile.LocalPath 'Downloads'
    if (-not (Test-Path -LiteralPath $downloadsPath)) {
        return [pscustomobject]@{ Items = @(); Reason = 'no Downloads folder found' }
    }
    $items = @(Get-ChildItem -LiteralPath $downloadsPath -Force -ErrorAction SilentlyContinue)
    if ($items.Count -eq 0) {
        return [pscustomobject]@{ Items = @(); Reason = 'Downloads folder already empty' }
    }
    return [pscustomobject]@{ Items = $items; Reason = '' }
}

function Invoke-DownloadsLockEscalation {
    <#
    .SYNOPSIS
        Handles Downloads items that could not be deleted because they are locked: if
        the owning account is signed in and is not protected, signs that session out
        and retries just those items once.
    .PARAMETER Profile
        The Win32_UserProfile CIM instance.
    .PARAMETER Label
        The profile's bare account name, for logging.
    .PARAMETER FailedItems
        The items that failed the first delete pass.
    .PARAMETER Sessions
        The session list from Get-InteractiveSessions.
    .PARAMETER IsUntouchable
        Whether the profile is protected; suppresses the logoff entirely.
    .OUTPUTS
        [pscustomobject] { ForcedLogoff (bool); FailedItems (still-undeletable items) }
    #>
    param(
        [Parameter(Mandatory)][Object]$Profile,
        [Parameter(Mandatory)][String]$Label,
        [Object]$FailedItems,
        [Object[]]$Sessions = @(),
        [Bool]$IsUntouchable = $false
    )

    $remaining = $FailedItems
    $forcedLogoff = $false

    if ($remaining.Count -eq 0) {
        return [pscustomobject]@{ ForcedLogoff = $forcedLogoff; FailedItems = $remaining }
    }
    if ($IsUntouchable) {
        Write-CleanupLog -Severity Warning -Message "Downloads cleanup for '$Label': $($remaining.Count) item(s) locked, but this profile is protected - not forcing a logoff; they will be retried next run."
        return [pscustomobject]@{ ForcedLogoff = $forcedLogoff; FailedItems = $remaining }
    }
    if (-not (Test-SidHasInteractiveSession -Sid $Profile.SID -Sessions $Sessions)) {
        return [pscustomobject]@{ ForcedLogoff = $forcedLogoff; FailedItems = $remaining }
    }

    Write-CleanupLog -Message "Downloads cleanup for '$Label': $($remaining.Count) item(s) locked; forcing logoff to release them."
    $forcedLogoff = Invoke-ForceLogoff -Sid $Profile.SID -Label $Label -Sessions $Sessions
    if ($forcedLogoff) {
        Start-Sleep -Seconds 5
        $remaining = Remove-DownloadsItems -Items $remaining
    }
    return [pscustomobject]@{ ForcedLogoff = $forcedLogoff; FailedItems = $remaining }
}

function Get-DownloadsPurgeDetail {
    <#
    .SYNOPSIS
        Formats the one-line Downloads purge result used in the log and notification.
    .PARAMETER Found
        Items found in the folder.
    .PARAMETER Deleted
        Items successfully deleted.
    .PARAMETER Failed
        Items still undeletable.
    .PARAMETER ForcedLogoff
        Whether a session was signed out to release locks.
    .OUTPUTS
        The detail string.
    #>
    param(
        [Parameter(Mandatory)][Int32]$Found,
        [Parameter(Mandatory)][Int32]$Deleted,
        [Parameter(Mandatory)][Int32]$Failed,
        [Bool]$ForcedLogoff = $false
    )
    $detail = "deleted $Deleted/$Found item(s) from Downloads"
    if ($ForcedLogoff) { $detail += ' (forced logoff to release locks)' }
    if ($Failed -gt 0) { $detail += "; $Failed still locked/failed" }
    return $detail
}

function Get-DownloadsInventory {
    <#
    .SYNOPSIS
        Read-only metadata scan of a profile's Downloads folder - filename, size, and
        both LastAccessTime/LastWriteTime for every file. Built ahead of a planned
        future feature (a per-user reminder about Downloads folder size); the caller
        currently discards the result.
    .PARAMETER ProfilePath
        Full path to the profile root.
    .OUTPUTS
        Array of [pscustomobject] { Name; SizeBytes; LastAccessTime; LastWriteTime }.
        NOTE: NTFS last-access-time updates are OFF by default since Windows Vista and
        remain off by default on Windows 10/11, so LastAccessTime typically will NOT
        reflect when a file was actually last opened - LastWriteTime is included for
        that reason.
    #>
    param([Parameter(Mandatory)][String]$ProfilePath)

    $downloadsPath = Join-Path $ProfilePath 'Downloads'
    if (-not (Test-Path -LiteralPath $downloadsPath)) { return @() }

    return @(Get-ChildItem -LiteralPath $downloadsPath -File -Force -Recurse -ErrorAction SilentlyContinue | ForEach-Object {
        [pscustomobject]@{
            Name           = $_.Name
            SizeBytes      = $_.Length
            LastAccessTime = $_.LastAccessTime
            LastWriteTime  = $_.LastWriteTime
        }
    })
}
#endregion

#region Notification
function Send-CleanupNotification {
    <#
    .SYNOPSIS
        Posts a compact JSON run summary to an admin-configured webhook (typically a
        Power Automate flow that emails or Teams-messages the result). Best-effort
        only - a webhook outage or a bad URL must never fail the cleanup run itself.
    .PARAMETER WebhookUrl
        The HTTP endpoint to POST the summary to.
    .PARAMETER Summary
        The summary object (see Get-NotificationSummary) to send as JSON.
    .OUTPUTS
        None.
    #>
    param(
        [Parameter(Mandatory)][String]$WebhookUrl,
        [Parameter(Mandatory)][Object]$Summary
    )
    try {
        # Sent as UTF-8 bytes, not a string: a string body is encoded with the system
        # codepage, which corrupts any non-ASCII character (e.g. an account named
        # "DanielJonsson" with an o-umlaut) and the endpoint rejects it as malformed.
        $body = [System.Text.Encoding]::UTF8.GetBytes(($Summary | ConvertTo-Json -Depth 5 -Compress))
        Invoke-RestMethod -Method Post -Uri $WebhookUrl -Body $body -ContentType 'application/json; charset=utf-8' -TimeoutSec 30 | Out-Null
        Write-CleanupLog -Message 'Sent run summary to the configured notification webhook.'
    } catch {
        Write-CleanupLog -Severity Warning -Message "Failed to send notification to the configured webhook: $_"
    }
}
#endregion

#region Profile evaluation
function Resolve-ProfileIdentity {
    <#
    .SYNOPSIS
        Resolves a profile's SID to an account name, and derives the bare (domain-
        prefix-stripped) display label used throughout logging/reporting. Falls back
        to the raw SID as the label if the account no longer resolves (an orphaned
        profile - exactly what this script targets).
    .PARAMETER Sid
        The profile's SID.
    .OUTPUTS
        [pscustomobject] { AccountName (raw, may be $null); Label (bare, never $null) }
    #>
    param([Parameter(Mandatory)][String]$Sid)

    $accountName = $null
    try {
        $accountName = ([System.Security.Principal.SecurityIdentifier]$Sid).Translate([System.Security.Principal.NTAccount]).Value
    } catch {
        # Common for a profile whose AD/Azure AD account no longer exists - exactly
        # the kind of orphaned profile this script exists to clean up.
    }
    $label = if ($accountName) { $accountName -replace '^.*\\' } else { $Sid }
    return [pscustomobject]@{ AccountName = $accountName; Label = $label }
}

function Get-ProfileUnloadTime {
    <#
    .SYNOPSIS
        Reads a profile's last unload time from its ProfileList registry entry
        (LocalProfileUnloadTimeHigh/Low, a split FILETIME). This is when the user
        actually last finished using the device.
    .PARAMETER Sid
        The profile's SID.
    .OUTPUTS
        [DateTime], or $null if the values are absent or unreadable.
    #>
    param([Parameter(Mandatory)][String]$Sid)

    $key = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList\$Sid"
    try {
        $props = Get-ItemProperty -LiteralPath $key -ErrorAction Stop
    } catch {
        return $null
    }
    if ($null -eq $props.LocalProfileUnloadTimeHigh -or $null -eq $props.LocalProfileUnloadTimeLow) { return $null }
    try {
        $fileTime = ([int64]$props.LocalProfileUnloadTimeHigh -shl 32) -bor ([int64]$props.LocalProfileUnloadTimeLow -band 0xFFFFFFFF)
        if ($fileTime -le 0) { return $null }
        return [DateTime]::FromFileTime($fileTime)
    } catch {
        return $null
    }
}

function Get-NtUserDatWriteTime {
    <#
    .SYNOPSIS
        Reads the last-write time of a profile's NTUSER.DAT, which Windows flushes when
        the profile unloads. Fallback for when the registry unload time is missing.
    .PARAMETER LocalPath
        The profile folder path.
    .OUTPUTS
        [DateTime], or $null if the file is missing or unreadable.
    #>
    param([String]$LocalPath)

    if ([string]::IsNullOrWhiteSpace($LocalPath)) { return $null }
    $item = Get-Item -LiteralPath (Join-Path $LocalPath 'NTUSER.DAT') -Force -ErrorAction SilentlyContinue
    if ($item) { return $item.LastWriteTime }
    return $null
}

function Get-ProfileActivityTime {
    <#
    .SYNOPSIS
        Returns the most recent write time across a few folders that a user's own
        activity keeps touching (temp files, jump lists, browser profile, shell
        folders).

        This is the only signal that advances *during* a session. The hive timestamps
        all freeze at sign-in, so after a long session ends in a reboot they would make
        a heavily-used profile look untouched since the day it started. Only the
        folders themselves are stat'ed - no recursion - so this stays cheap.
    .PARAMETER LocalPath
        The profile folder path.
    .PARAMETER RelativePaths
        Folders to check, relative to the profile (ActivityPaths from the config).
    .OUTPUTS
        [pscustomobject] { Time ([DateTime] or $null); Path (which folder it came from) }
    #>
    param(
        [String]$LocalPath,
        [String[]]$RelativePaths = @()
    )

    $result = [pscustomobject]@{ Time = $null; Path = '' }
    if ([string]::IsNullOrWhiteSpace($LocalPath)) { return $result }

    foreach ($relative in $RelativePaths) {
        $item = Get-Item -LiteralPath (Join-Path $LocalPath $relative) -Force -ErrorAction SilentlyContinue
        if ($item -and ($null -eq $result.Time -or $item.LastWriteTime -gt $result.Time)) {
            $result.Time = $item.LastWriteTime
            $result.Path = $relative
        }
    }
    return $result
}

function Get-ProfileLastUsed {
    <#
    .SYNOPSIS
        Determines when a profile was genuinely last used, and which signal said so.

        A live session means in use now. Otherwise every available signal is gathered
        and the NEWEST one wins, because each covers a different gap: the hive
        timestamps freeze for the whole of a session (so a long session that ends in a
        reboot would otherwise look untouched since it began), while activity folders
        only move when the user does something. Taking the latest evidence errs toward
        keeping a profile, which is the safe direction.

        Win32_UserProfile.LastUseTime is used only as a last resort and only for an
        unloaded profile - for a loaded one it just returns the current time.
    .PARAMETER Profile
        The Win32_UserProfile CIM instance.
    .PARAMETER Sessions
        The session list from Get-InteractiveSessions.
    .PARAMETER Now
        The current time, used when the profile is signed in.
    .PARAMETER ActivityPaths
        Folders treated as user activity (ActivityPaths from the config).
    .OUTPUTS
        [pscustomobject] { LastUsed ([DateTime] or $null); Source (string); Signals }
    #>
    param(
        [Parameter(Mandatory)][Object]$Profile,
        [Object[]]$Sessions = @(),
        [Parameter(Mandatory)][DateTime]$Now,
        [String[]]$ActivityPaths = @()
    )

    $unload   = Get-ProfileUnloadTime -Sid $Profile.SID
    $activity = Get-ProfileActivityTime -LocalPath $Profile.LocalPath -RelativePaths $ActivityPaths
    $ntuser   = Get-NtUserDatWriteTime -LocalPath $Profile.LocalPath
    $lastUse  = if ($Profile.LastUseTime) { $Profile.LastUseTime } else { $null }
    $signals  = Format-ProfileSignals -Unload $unload -Activity $activity.Time -ActivityPath $activity.Path -NtUser $ntuser -LastUseTime $lastUse -Loaded ([bool]$Profile.Loaded)

    if (Test-SidHasInteractiveSession -Sid $Profile.SID -Sessions $Sessions) {
        return [pscustomobject]@{ LastUsed = $Now; Source = 'signed in now'; Signals = $signals }
    }

    # A hive that is loaded but has never once unloaded is a system-loaded account, not
    # somebody's stale profile. Its activity folders were written when the image was
    # built and never since, so trusting them yields an age of years - a false "stale"
    # that would make it a deletion candidate. Report it as unknown, which keeps it.
    if ($Profile.Loaded -and -not $unload) {
        return [pscustomobject]@{ LastUsed = $null; Source = 'unknown (loaded, never unloaded)'; Signals = $signals }
    }

    # Only the profile service's unload time and the user's own activity folders are
    # trusted. NTUSER.DAT is deliberately excluded here: servicing, policy processing
    # and management agents all rewrite it on machines where nobody has signed in for
    # months, which made it report those profiles as fresh. It is kept only as a
    # last-resort answer when nothing trustworthy exists at all.
    $trusted = @(
        [pscustomobject]@{ Time = $unload;        Source = 'profile unload time' }
        [pscustomobject]@{ Time = $activity.Time; Source = "recent activity ($($activity.Path))" }
    ) | Where-Object { $_.Time }

    $newest = $trusted | Sort-Object -Property Time -Descending | Select-Object -First 1
    if ($newest) {
        return [pscustomobject]@{ LastUsed = $newest.Time; Source = $newest.Source; Signals = $signals }
    }
    if ($ntuser) {
        return [pscustomobject]@{ LastUsed = $ntuser; Source = 'NTUSER.DAT (untrusted fallback)'; Signals = $signals }
    }
    if ($lastUse -and -not $Profile.Loaded) {
        return [pscustomobject]@{ LastUsed = $lastUse; Source = 'LastUseTime (untrusted fallback)'; Signals = $signals }
    }
    return [pscustomobject]@{ LastUsed = $null; Source = 'unknown (no usable timestamp)'; Signals = $signals }
}

function Format-ProfileSignals {
    <#
    .SYNOPSIS
        Renders every last-used signal as one compact string for the log and report, so
        a wrong age can be traced to the signal that caused it without visiting the
        device.
    .PARAMETER Unload
        The profile unload time, or $null.
    .PARAMETER Activity
        The newest activity-folder time, or $null.
    .PARAMETER ActivityPath
        Which folder that activity time came from.
    .PARAMETER NtUser
        The NTUSER.DAT write time, or $null.
    .PARAMETER LastUseTime
        Win32_UserProfile.LastUseTime, or $null.
    .PARAMETER Loaded
        Whether the profile hive is currently loaded.
    .OUTPUTS
        A string such as "unload=2026-05-29 14:02 activity=2026-07-25 23:05 [Downloads]
        ntuser=2026-07-24 03:11 lastuse=2026-07-24 03:11 loaded=False". Times are local
        and include the clock time so an age can be correlated against a known session
        or against this task's own run time.
    #>
    param(
        $Unload,
        $Activity,
        [String]$ActivityPath = '',
        $NtUser,
        $LastUseTime,
        [Bool]$Loaded = $false
    )
    $format = {
        param($value)
        if ($value) { ([DateTime]$value).ToString('yyyy-MM-dd HH:mm') } else { '-' }
    }
    $activityText = & $format $Activity
    if ($Activity -and $ActivityPath) { $activityText = "$activityText [$ActivityPath]" }
    return "unload=$(& $format $Unload) activity=$activityText ntuser=$(& $format $NtUser) lastuse=$(& $format $LastUseTime) loaded=$Loaded"
}

function Get-ProfileAgeInfo {
    <#
    .SYNOPSIS
        Computes a profile's age in days from a resolved last-used time, plus a
        human-readable label that names the source so the reasoning is auditable.
    .PARAMETER LastUsed
        The resolved last-used time (see Get-ProfileLastUsed), or $null.
    .PARAMETER Source
        Where that time came from, included in the label.
    .PARAMETER Now
        The current time to measure age against.
    .OUTPUTS
        [pscustomobject] { AgeDays (int, or $null if unknown); AgeLabel }
    #>
    param(
        $LastUsed,
        [String]$Source = 'unknown',
        [Parameter(Mandatory)][DateTime]$Now
    )
    if ($null -eq $LastUsed) {
        # $Source already carries the full explanation for a null result (e.g. 'unknown
        # (loaded, never unloaded)') - previously discarded here in favor of one generic
        # string, so that more specific reason never reached the report.
        return [pscustomobject]@{ AgeDays = $null; AgeLabel = $Source }
    }
    $ageDays = [Math]::Floor(($Now - $LastUsed).TotalDays)
    if ($ageDays -lt 0) { $ageDays = 0 }
    return [pscustomobject]@{ AgeDays = $ageDays; AgeLabel = "$ageDays day(s) ago (via $Source)" }
}

function Get-ProfileSizeInfo {
    <#
    .SYNOPSIS
        Computes a profile's on-disk size in MB (Get-ProfileSizeBytes) when
        IncludeProfileSize is enabled, and a human-readable label for logging. This is
        the single most expensive step per profile.
    .PARAMETER LocalPath
        The profile's local folder path (may be $null/empty).
    .PARAMETER IncludeProfileSize
        Whether to actually compute the size.
    .PARAMETER TopFolderCount
        How many folders to list for an oversized profile.
    .PARAMETER TopFolderMinMB
        Only list folders for profiles at least this large; 0 lists them for every
        profile. To turn the listing off entirely, set TopFolderCount to 0. The scan
        happens either way, so this controls report size, not run time.
    .PARAMETER AdditionalDehydrateFolders
        Extra synced folders from the config, so the dehydratable figure covers the
        same folders dehydration itself would act on.
    .OUTPUTS
        [pscustomobject] { SizeMB (decimal, or $null); SizeLabel (string);
        TopFolders (string, empty unless the profile is over TopFolderMinMB);
        DehydratableMB (what dehydration could still release) }
    #>
    param(
        [String]$LocalPath,
        [Parameter(Mandatory)][Bool]$IncludeProfileSize,
        [Int32]$TopFolderCount = 10,
        [Int32]$TopFolderMinMB = 0,
        [String[]]$AdditionalDehydrateFolders = @()
    )
    $sizeMB = $null
    $topFolders = ''
    $dehydratableMB = 0
    if ($IncludeProfileSize -and $LocalPath) {
        $breakdown = Get-ProfileSizeBreakdown -Path $LocalPath
        if ($null -ne $breakdown) {
            $sizeMB = [Math]::Round($breakdown.TotalBytes / 1MB, 1)
            $syncFolders = @(Get-OneDriveSyncFolders -ProfilePath $LocalPath -AdditionalRelativePaths $AdditionalDehydrateFolders)
            $dehydratableMB = [Math]::Round((Get-DehydratableBytes -Folders $breakdown.Folders -ProfilePath $LocalPath -SyncFolders $syncFolders) / 1MB, 1)
            if ($sizeMB -ge $TopFolderMinMB) {
                $adaptive = Get-AdaptiveFolderTotals -Folders $breakdown.Folders -TotalBytes $breakdown.TotalBytes
                $topFolders = Format-TopFolders -Folders $adaptive -Count $TopFolderCount
            }
        }
    }
    $sizeLabel = if ($null -ne $sizeMB) { "$sizeMB MB" } else { 'unknown' }
    return [pscustomobject]@{ SizeMB = $sizeMB; SizeLabel = $sizeLabel; TopFolders = $topFolders; DehydratableMB = $dehydratableMB }
}

function Test-DownloadsPurgeTarget {
    <#
    .SYNOPSIS
        Determines whether a profile is a configured Downloads-purge target, matched
        either by resolved SID or by its bare account label - either is sufficient,
        so a rename doesn't silently stop the match from applying.
    .PARAMETER Sid
        The profile's SID.
    .PARAMETER Label
        The profile's bare account label.
    .PARAMETER PurgeSids
        Resolved purge-target SIDs (see Resolve-DownloadsPurgeSids).
    .PARAMETER PurgeUsernames
        Configured purge-target usernames (DownloadsPurgeUsernames).
    .OUTPUTS
        [bool]
    #>
    param(
        [Parameter(Mandatory)][String]$Sid,
        [Parameter(Mandatory)][String]$Label,
        [Parameter(Mandatory)][Object]$PurgeSids,
        [String[]]$PurgeUsernames = @()
    )
    if ($PurgeSids.Contains($Sid)) { return $true }
    return [bool]($PurgeUsernames | Where-Object { $_ -ieq $Label })
}

function Invoke-DownloadsHandling {
    <#
    .SYNOPSIS
        Handles a profile's Downloads folder: unconditionally empties it if the
        profile is a purge target (Clear-DownloadsFolder), otherwise scans it
        read-only and discards the result if ScanDownloads is on (Get-DownloadsInventory).
    .PARAMETER Profile
        The Win32_UserProfile CIM instance.
    .PARAMETER Label
        The profile's bare account label, for logging.
    .PARAMETER IsPurgeTarget
        Whether this profile is a configured Downloads-purge target.
    .PARAMETER ScanDownloads
        Whether to run the discard-only scan for non-purge-target profiles.
    .PARAMETER Sessions
        The session list from Get-InteractiveSessions, for the locked-file logoff path.
    .PARAMETER IsUntouchable
        Whether this profile is the last or primary user (suppresses force-logoff only).
    .OUTPUTS
        [pscustomobject] { Detail (string, empty unless IsPurgeTarget);
        FreedBytes (space actually released) }
    #>
    param(
        [Parameter(Mandatory)][Object]$Profile,
        [Parameter(Mandatory)][String]$Label,
        [Parameter(Mandatory)][Bool]$IsPurgeTarget,
        [Parameter(Mandatory)][Bool]$ScanDownloads,
        [Object[]]$Sessions = @(),
        [Bool]$IsUntouchable = $false
    )
    if ($IsPurgeTarget) {
        $purge = Clear-DownloadsFolder -Profile $Profile -Label $Label -Sessions $Sessions -IsUntouchable $IsUntouchable
        return [pscustomobject]@{ Detail = $purge.Detail; FreedBytes = $purge.BytesDeleted }
    }
    if ($ScanDownloads -and $Profile.LocalPath) {
        # Scanned and immediately discarded - see Get-DownloadsInventory.
        $null = Get-DownloadsInventory -ProfilePath $Profile.LocalPath
    }
    return [pscustomobject]@{ Detail = ''; FreedBytes = [int64]0 }
}

function Get-ProfileKeepReason {
    <#
    .SYNOPSIS
        Determines why a profile should be kept (protected from deletion), if any.
        Checked in order: most-recently-used, Intune primary user, excluded by SID,
        excluded by username, undeterminable age, or not yet past RetentionDays.
    .PARAMETER Profile
        The Win32_UserProfile CIM instance.
    .PARAMETER Sid
        The profile's SID.
    .PARAMETER AccountName
        The profile's raw resolved account name (may be $null).
    .PARAMETER RecentSids
        The most-recently-used profile SIDs, newest first (see Get-RecentlyUsedSids).
    .PARAMETER Config
        The effective config.
    .PARAMETER AgeDays
        The profile's age in days (see Get-ProfileAgeInfo).
    .OUTPUTS
        The keep-reason string, or $null if the profile is a genuine deletion candidate.
    #>
    param(
        [Parameter(Mandatory)][Object]$Profile,
        [Parameter(Mandatory)][String]$Sid,
        [String]$AccountName,
        [String[]]$RecentSids = @(),
        [Parameter(Mandatory)][Object]$Config,
        $AgeDays
    )
    # Recency also covers whoever is signed in: a live session resolves to "now", so it
    # always sorts first. A loaded hive on its own is not a protection.
    $rank = Get-RecentUseRank -Sid $Sid -RecentSids $RecentSids
    if ($rank -gt 0) {
        return "$(Get-RecentUseRankLabel -Rank $rank) profile on this device"
    }
    $exclusion = Get-ProfileExclusionReason -Sid $Sid -AccountName $AccountName -Config $Config
    if ($exclusion) {
        return $exclusion
    }
    if ($null -eq $AgeDays) {
        return 'last use could not be determined'
    }
    if ($AgeDays -lt $Config.RetentionDays) {
        return "not yet past the retention window ($($Config.RetentionDays) day(s))"
    }
    return $null
}

function Get-ProfileExclusionReason {
    <#
    .SYNOPSIS
        Determines whether a profile is in the configured exclusion lists, matched by
        SID or by account name (with or without a domain prefix).
    .PARAMETER Sid
        The profile's SID.
    .PARAMETER AccountName
        The profile's resolved account name, or $null if it no longer resolves.
    .PARAMETER Config
        The effective config.
    .OUTPUTS
        The reason string for the log, or $null if the profile is not excluded.
    #>
    param(
        [Parameter(Mandatory)][String]$Sid,
        [String]$AccountName,
        [Parameter(Mandatory)][Object]$Config
    )
    if ($Config.ExcludedSids -contains $Sid) {
        return 'SID is in the configured exclusion list'
    }
    if ($AccountName -and ($Config.ExcludedUsernames | Where-Object { $_ -ieq $AccountName -or $_ -ieq ($AccountName -replace '^.*\\') })) {
        return 'username is in the configured exclusion list'
    }
    return $null
}

function Get-RecentUseRank {
    <#
    .SYNOPSIS
        Returns a profile's position in the recently-used list.
    .PARAMETER Sid
        The profile's SID.
    .PARAMETER RecentSids
        The most-recently-used SIDs, newest first (see Get-RecentlyUsedSids).
    .OUTPUTS
        [int] 1-based rank (1 = most recent), or 0 if the SID is not in the list.
    #>
    param(
        [Parameter(Mandatory)][String]$Sid,
        [String[]]$RecentSids = @()
    )
    for ($i = 0; $i -lt $RecentSids.Count; $i++) {
        if ($RecentSids[$i] -ieq $Sid) { return $i + 1 }
    }
    return 0
}

function Get-RecentUseRankLabel {
    <#
    .SYNOPSIS
        Renders a 1-based recency rank as readable text for logs and notifications.
    .PARAMETER Rank
        The 1-based rank (see Get-RecentUseRank).
    .OUTPUTS
        A string such as "most recently used" or "2nd most recently used".
    #>
    param([Parameter(Mandatory)][Int32]$Rank)
    switch ($Rank) {
        1 { return 'most recently used' }
        2 { return '2nd most recently used' }
        3 { return '3rd most recently used' }
        default { return "$($Rank)th most recently used" }
    }
}

function Test-ProfileIsUntouchable {
    <#
    .SYNOPSIS
        Determines whether a profile must never be disrupted by a forceful action
        (force-logoff, hive unload, dehydration). True for the ProtectedRecentUsers
        most recently used profiles, and for any profile the config excludes -
        "always keep this profile" is taken to mean "leave it alone entirely". The
        single guard all such actions check.
    .PARAMETER Sid
        The profile's SID.
    .PARAMETER RecentSids
        The most-recently-used SIDs, newest first (see Get-RecentlyUsedSids).
    .PARAMETER IsExcluded
        Whether the profile is in the config's exclusion lists.
    .OUTPUTS
        [bool] $true if the profile must be left alone.
    #>
    param(
        [Parameter(Mandatory)][String]$Sid,
        [String[]]$RecentSids = @(),
        [Bool]$IsExcluded = $false
    )
    if ($IsExcluded) { return $true }
    return ((Get-RecentUseRank -Sid $Sid -RecentSids $RecentSids) -gt 0)
}

function Get-BrowserCacheFolders {
    <#
    .SYNOPSIS
        Resolves the configured browser cache patterns to folders that exist in one
        profile. Patterns carry wildcards because every browser keeps one cache per
        browser profile - "Default", "Profile 1", and Firefox's randomly named
        profile folders - and a fixed path would only ever find the first.
    .PARAMETER ProfilePath
        The profile root the patterns are relative to.
    .PARAMETER Patterns
        Relative paths, wildcards allowed (BrowserCachePaths from the config).
    .OUTPUTS
        [System.IO.DirectoryInfo[]] the cache folders that exist.
    #>
    param(
        [Parameter(Mandatory)][String]$ProfilePath,
        [String[]]$Patterns = @()
    )
    $found = New-Object System.Collections.Generic.List[System.IO.DirectoryInfo]
    foreach ($pattern in $Patterns) {
        if ([string]::IsNullOrWhiteSpace($pattern)) { continue }
        foreach ($match in (Get-Item -Path (Join-Path $ProfilePath $pattern) -Force -ErrorAction SilentlyContinue)) {
            if ($match.PSIsContainer) { $found.Add($match) }
        }
    }
    return $found.ToArray()
}

function Save-ActivityFolderTimes {
    <#
    .SYNOPSIS
        Records the last-write time of the folders that decide a profile's age,
        before anything is deleted inside the profile.

        Those timestamps ARE the age signal, and a folder's timestamp moves whenever
        an entry is added or removed from it. Clearing a browser cache without this
        would make the profile look used today - verified: a folder last written 60
        days ago read as the current time the moment a subfolder was deleted. Every
        cleaned profile would then look fresh forever and could never go stale, which
        would quietly disable profile deletion altogether.
    .PARAMETER LocalPath
        The profile folder.
    .PARAMETER RelativePaths
        The folders that carry the age signal (ActivityPaths from the config).
    .OUTPUTS
        [hashtable] full path -> the time it had before.
    #>
    param(
        [Parameter(Mandatory)][String]$LocalPath,
        [String[]]$RelativePaths = @()
    )
    $saved = @{}
    foreach ($relative in $RelativePaths) {
        if ([string]::IsNullOrWhiteSpace($relative)) { continue }
        $item = Get-Item -LiteralPath (Join-Path $LocalPath $relative) -Force -ErrorAction SilentlyContinue
        if ($item) { $saved[$item.FullName] = $item.LastWriteTime }
    }
    return $saved
}

function Restore-ActivityFolderTimes {
    <#
    .SYNOPSIS
        Puts back the timestamps captured by Save-ActivityFolderTimes, so that
        tidying up inside a profile cannot be mistaken for the user having used it.
    .PARAMETER SavedTimes
        The hashtable from Save-ActivityFolderTimes.
    .OUTPUTS
        [Int32] how many folders were restored.
    #>
    param([Object]$SavedTimes = @{})
    $restored = 0
    foreach ($path in $SavedTimes.Keys) {
        try {
            $item = Get-Item -LiteralPath $path -Force -ErrorAction Stop
            if ($item.LastWriteTime -ne $SavedTimes[$path]) {
                $item.LastWriteTime = $SavedTimes[$path]
                $restored++
            }
        } catch {
            continue
        }
    }
    return $restored
}

function Clear-FolderContents {
    <#
    .SYNOPSIS
        Empties a folder without removing the folder itself, measuring what actually
        went. Keeping the folder matters: removing it would change its parent's
        timestamp too, widening the blast radius on the age signal for no benefit,
        and browsers recreate the contents but expect the folder to be there.
    .PARAMETER Folder
        The folder to empty.
    .OUTPUTS
        [pscustomobject] { FreedBytes; Failed } - Failed counts items still in place.
    #>
    param([Parameter(Mandatory)][System.IO.DirectoryInfo]$Folder)
    $freed = [int64]0
    $failed = 0
    foreach ($item in (Get-ChildItem -LiteralPath $Folder.FullName -Force -ErrorAction SilentlyContinue)) {
        $size = Get-ItemSizeBytes -Item $item
        try {
            Remove-Item -LiteralPath $item.FullName -Recurse -Force -ErrorAction Stop
            $freed += $size
        } catch {
            $failed++
        }
    }
    return [pscustomobject]@{ FreedBytes = $freed; Failed = $failed }
}

function Invoke-ProfileBrowserCacheCleanup {
    <#
    .SYNOPSIS
        Clears browser caches for one profile. Gated only on nobody being signed into
        the account - not on staleness, because the caches worth clearing belong to
        the accounts in daily use, which are the ones staleness protects.

        Runs regardless of LogOnly, in the same way dehydration does: a browser cache
        is disposable by design and is rebuilt on next use, so this costs the user
        nothing beyond a slower first page load.

        The age signal is saved before and restored after, so cleaning cannot make a
        profile look freshly used.
    .PARAMETER Profile
        The Win32_UserProfile CIM instance.
    .PARAMETER Config
        The effective config.
    .PARAMETER Sessions
        The session list from Get-InteractiveSessions.
    .PARAMETER Label
        The account's display label, for logging.
        The caches are measured whether or not they are cleared, so the report always
        carries the size of the opportunity. Without that the figure reads zero on
        every run while ClearBrowserCaches is off, which is exactly when somebody is
        deciding whether turning it on is worthwhile.
    .OUTPUTS
        [pscustomobject] { Detail (string, empty when nothing applied); FreedBytes
        (actually released this run); FreeableBytes (still there to release) }
    #>
    param(
        [Parameter(Mandatory)][Object]$Profile,
        [Parameter(Mandatory)][Object]$Config,
        [Object[]]$Sessions = @(),
        [Parameter(Mandatory)][String]$Label
    )
    $result = [pscustomobject]@{ Detail = ''; FreedBytes = [int64]0; FreeableBytes = [int64]0 }
    if (-not $Profile.LocalPath) { return $result }

    $folders = @(Get-BrowserCacheFolders -ProfilePath $Profile.LocalPath -Patterns $Config.BrowserCachePaths)
    if ($folders.Count -eq 0) { return $result }

    $signedIn = Test-SidHasInteractiveSession -Sid $Profile.SID -Sessions $Sessions
    if (-not $Config.ClearBrowserCaches -or $signedIn) {
        foreach ($folder in $folders) { $result.FreeableBytes += Get-ItemSizeBytes -Item $folder }
        if ($signedIn -and $Config.ClearBrowserCaches) {
            $result.Detail = "skipped browser cache cleanup: the account is signed in ($(Format-FolderSize -Bytes $result.FreeableBytes) could be freed)"
        }
        return $result
    }

    $savedTimes = Save-ActivityFolderTimes -LocalPath $Profile.LocalPath -RelativePaths $Config.ActivityPaths
    $failed = 0
    foreach ($folder in $folders) {
        $cleared = Clear-FolderContents -Folder $folder
        $result.FreedBytes += $cleared.FreedBytes
        $failed += $cleared.Failed
    }
    $restored = Restore-ActivityFolderTimes -SavedTimes $savedTimes

    $result.Detail = "cleared $($folders.Count) browser cache folder(s), freed $(Format-FolderSize -Bytes $result.FreedBytes)"
    if ($failed -gt 0) { $result.Detail = "$($result.Detail), $failed item(s) in use" }
    if ($restored -gt 0) { $result.Detail = "$($result.Detail); restored $restored activity timestamp(s)" }
    Write-CleanupLog -Message "Browser cache cleanup for '$Label': $($result.Detail)."
    return $result
}

function Get-KnownFolderValueName {
    <#
    .SYNOPSIS
        Maps a folder's everyday name to the value name Windows stores its location
        under in "User Shell Folders". Only folders OneDrive's Known Folder Move does
        not cover are listed: KFM handles Desktop, Documents and Pictures itself, and
        competing with it would fight the policy.
    .PARAMETER Name
        The folder's everyday name, e.g. "Videos".
    .OUTPUTS
        [String] the registry value name, or $null if the folder isn't one this
        supports.
    #>
    param([Parameter(Mandatory)][String]$Name)
    switch ($Name.Trim().ToLowerInvariant()) {
        'videos'    { return 'My Video' }
        'music'     { return 'My Music' }
        'downloads' { return '{374DE290-123F-4565-9164-39C4925E467B}' }
        default     { return $null }
    }
}

function Mount-UserProfileHive {
    <#
    .SYNOPSIS
        Makes a signed-out profile's registry hive readable and writable, loading
        NTUSER.DAT under HKU\<SID> only if it isn't already there. Reports whether it
        did the loading, because a hive this function mounted must be unmounted again
        afterwards while one that was already present must be left alone.
    .PARAMETER Sid
        The profile's SID, used as the key name under HKU.
    .PARAMETER LocalPath
        The profile folder, where NTUSER.DAT lives.
    .OUTPUTS
        [pscustomobject] { Path (registry path to the hive); Mounted ($true if this
        call loaded it) }, or $null if the hive could not be made available.
    #>
    param(
        [Parameter(Mandatory)][String]$Sid,
        [Parameter(Mandatory)][String]$LocalPath
    )
    if (-not (Get-PSDrive -Name HKU -ErrorAction SilentlyContinue)) {
        New-PSDrive -Name HKU -PSProvider Registry -Root HKEY_USERS -Scope Script -ErrorAction SilentlyContinue | Out-Null
    }
    $path = "HKU:\$Sid"
    if (Test-Path -LiteralPath $path) {
        return [pscustomobject]@{ Path = $path; Mounted = $false }
    }
    $hiveFile = Join-Path $LocalPath 'NTUSER.DAT'
    if (-not (Test-Path -LiteralPath $hiveFile)) { return $null }
    & reg.exe load "HKU\$Sid" $hiveFile 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $path)) { return $null }
    return [pscustomobject]@{ Path = $path; Mounted = $true }
}

function Get-OneDriveRootFromHive {
    <#
    .SYNOPSIS
        Reads where a user's OneDrive folder lives, from their own registry hive.
        Used rather than guessing a path, because it is also the check that OneDrive
        is actually set up for that account - redirecting a folder into a OneDrive
        that was never configured would strand the files locally with nothing to
        sync them.
    .PARAMETER HivePath
        Registry path to the loaded hive (see Mount-UserProfileHive).
    .OUTPUTS
        [String] the OneDrive folder path, or $null if OneDrive isn't set up.
    #>
    param([Parameter(Mandatory)][String]$HivePath)
    $accounts = Join-Path $HivePath 'Software\Microsoft\OneDrive\Accounts'
    if (-not (Test-Path -LiteralPath $accounts)) { return $null }
    foreach ($account in (Get-ChildItem -LiteralPath $accounts -ErrorAction SilentlyContinue)) {
        $folder = (Get-ItemProperty -LiteralPath $account.PSPath -Name 'UserFolder' -ErrorAction SilentlyContinue).UserFolder
        if ($folder -and (Test-Path -LiteralPath $folder)) { return $folder }
    }
    return $null
}

function Test-SameFileContent {
    <#
    .SYNOPSIS
        Decides whether two files are the same file, by size and last-write time.
        Deliberately does not compare contents: the destination copy is usually an
        online-only OneDrive placeholder, and reading it would pull the whole file
        back down - the exact opposite of what this feature is for. Size and
        timestamp are what sync tools use for the same reason.
    .PARAMETER First
        One file.
    .PARAMETER Second
        The other file.
    .OUTPUTS
        [bool] $true if they look like the same file.
    #>
    param(
        [Parameter(Mandatory)][System.IO.FileInfo]$First,
        [Parameter(Mandatory)][System.IO.FileInfo]$Second
    )
    if ($First.Length -ne $Second.Length) { return $false }
    # A couple of seconds of tolerance: a file that has been round-tripped through
    # sync can come back with a marginally different timestamp.
    return ([Math]::Abs(($First.LastWriteTimeUtc - $Second.LastWriteTimeUtc).TotalSeconds) -le 2)
}

function Get-NonClashingPath {
    <#
    .SYNOPSIS
        Finds a free filename next to one that is taken, by adding a tag and then a
        counter if needed. Used so that two devices holding different files under the
        same name both survive the merge, and so the surviving copy says where it
        came from.
    .PARAMETER DesiredPath
        The path that is already taken.
    .PARAMETER Tag
        Text to insert before the extension, normally the device name.
    .OUTPUTS
        [String] a path that does not exist yet.
    #>
    param(
        [Parameter(Mandatory)][String]$DesiredPath,
        [Parameter(Mandatory)][String]$Tag
    )
    $folder = Split-Path -Path $DesiredPath -Parent
    $name = [System.IO.Path]::GetFileNameWithoutExtension($DesiredPath)
    $extension = [System.IO.Path]::GetExtension($DesiredPath)
    $candidate = Join-Path $folder "$name ($Tag)$extension"
    $counter = 2
    while (Test-Path -LiteralPath $candidate) {
        $candidate = Join-Path $folder "$name ($Tag $counter)$extension"
        $counter++
        if ($counter -gt 100) { return $null }
    }
    return $candidate
}

function Merge-FolderContent {
    <#
    .SYNOPSIS
        Merges one folder into another, so that content from every device ends up in
        OneDrive rather than only whichever device got there first. Recurses into
        folders that exist on both sides instead of skipping them, since skipping a
        colliding folder would strand everything inside it.

        Files are handled one at a time so a single locked or unreadable file doesn't
        abandon the rest:
          - not at the destination     -> moved across
          - the same file already there -> the local duplicate is removed, its content
                                           being already in OneDrive; leaving it would
                                           orphan a copy in a folder that is no longer
                                           the known folder, invisible and unsynced
          - a different file same name  -> moved under a tagged name so both survive
    .PARAMETER Source
        Folder to merge out of.
    .PARAMETER Destination
        Folder to merge into; created if missing.
    .PARAMETER Tag
        Text used to rename a genuine clash, normally the device name.
    .OUTPUTS
        [pscustomobject] { Moved; Renamed; Duplicate; Failed } item counts.
    #>
    param(
        [Parameter(Mandatory)][String]$Source,
        [Parameter(Mandatory)][String]$Destination,
        [Parameter(Mandatory)][String]$Tag
    )
    $moved = 0; $renamed = 0; $duplicate = 0; $failed = 0
    if (-not (Test-Path -LiteralPath $Destination)) {
        New-Item -ItemType Directory -Path $Destination -Force -ErrorAction SilentlyContinue | Out-Null
    }

    foreach ($item in (Get-ChildItem -LiteralPath $Source -Force -ErrorAction SilentlyContinue)) {
        $target = Join-Path $Destination $item.Name
        try {
            if (-not (Test-Path -LiteralPath $target)) {
                Move-Item -LiteralPath $item.FullName -Destination $target -Force -ErrorAction Stop
                $moved++
                continue
            }

            if ($item.PSIsContainer) {
                $nested = Merge-FolderContent -Source $item.FullName -Destination $target -Tag $Tag
                $moved += $nested.Moved
                $renamed += $nested.Renamed
                $duplicate += $nested.Duplicate
                $failed += $nested.Failed
                # Only removed once emptied, so nothing that failed to move is lost.
                if (-not (Get-ChildItem -LiteralPath $item.FullName -Force -ErrorAction SilentlyContinue)) {
                    Remove-Item -LiteralPath $item.FullName -Force -ErrorAction SilentlyContinue
                }
                continue
            }

            $existing = Get-Item -LiteralPath $target -Force -ErrorAction Stop
            if ($existing -is [System.IO.FileInfo] -and (Test-SameFileContent -First $item -Second $existing)) {
                Remove-Item -LiteralPath $item.FullName -Force -ErrorAction Stop
                $duplicate++
                continue
            }

            $free = Get-NonClashingPath -DesiredPath $target -Tag $Tag
            if (-not $free) { $failed++; continue }
            Move-Item -LiteralPath $item.FullName -Destination $free -Force -ErrorAction Stop
            $renamed++
        } catch {
            $failed++
        }
    }
    return [pscustomobject]@{ Moved = $moved; Renamed = $renamed; Duplicate = $duplicate; Failed = $failed }
}

function Set-KnownFolderRedirect {
    <#
    .SYNOPSIS
        Points a known folder at a new location in the user's hive. Writes only
        "User Shell Folders", which is the value Windows actually reads; the
        neighbouring "Shell Folders" key is a cache the shell rewrites itself at the
        next sign-in.
    .PARAMETER HivePath
        Registry path to the loaded hive.
    .PARAMETER ValueName
        The value name for this folder (see Get-KnownFolderValueName).
    .PARAMETER NewPath
        Where the folder should now live.
    .OUTPUTS
        [bool] $true if the value was written.
    #>
    param(
        [Parameter(Mandatory)][String]$HivePath,
        [Parameter(Mandatory)][String]$ValueName,
        [Parameter(Mandatory)][String]$NewPath
    )
    $key = Join-Path $HivePath 'Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders'
    if (-not (Test-Path -LiteralPath $key)) { return $false }
    try {
        New-ItemProperty -LiteralPath $key -Name $ValueName -Value $NewPath -PropertyType ExpandString -Force -ErrorAction Stop | Out-Null
        return $true
    } catch {
        return $false
    }
}

function Get-KnownFolderCurrentPath {
    <#
    .SYNOPSIS
        Reads where a known folder currently points in a user's hive, so a folder
        that has already been redirected is left as it is rather than moved twice.
    .PARAMETER HivePath
        Registry path to the loaded hive.
    .PARAMETER ValueName
        The value name for this folder.
    .OUTPUTS
        [String] the current path with any environment variables expanded, or $null.
    #>
    param(
        [Parameter(Mandatory)][String]$HivePath,
        [Parameter(Mandatory)][String]$ValueName
    )
    $key = Join-Path $HivePath 'Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders'
    $raw = (Get-ItemProperty -LiteralPath $key -Name $ValueName -ErrorAction SilentlyContinue).$ValueName
    if ([string]::IsNullOrWhiteSpace($raw)) { return $null }
    return [Environment]::ExpandEnvironmentVariables($raw)
}

function Invoke-KnownFolderRedirect {
    <#
    .SYNOPSIS
        Redirects one known folder into the profile's OneDrive folder and moves its
        contents there, so that from now on the files sync instead of only ever
        sitting on this disk. OneDrive uploads them the next time that user signs in;
        a later run can then dehydrate them like any other synced folder.

        Does nothing if the folder is already somewhere inside OneDrive.
    .PARAMETER FolderName
        The folder's everyday name, e.g. "Videos".
    .PARAMETER HivePath
        Registry path to the user's loaded hive.
    .PARAMETER ProfilePath
        The profile folder.
    .PARAMETER OneDriveRoot
        The user's OneDrive folder.
    .PARAMETER WhatIfOnly
        Report what would happen without moving anything or touching the registry.
    .OUTPUTS
        [String] a description of what happened, or '' when there was nothing to do.
    #>
    param(
        [Parameter(Mandatory)][String]$FolderName,
        [Parameter(Mandatory)][String]$HivePath,
        [Parameter(Mandatory)][String]$ProfilePath,
        [Parameter(Mandatory)][String]$OneDriveRoot,
        [Bool]$WhatIfOnly = $true
    )
    $valueName = Get-KnownFolderValueName -Name $FolderName
    if (-not $valueName) { return "$FolderName is not a folder this can redirect" }

    $current = Get-KnownFolderCurrentPath -HivePath $HivePath -ValueName $valueName
    if (-not $current) { $current = Join-Path $ProfilePath $FolderName }
    if ($current -like "$OneDriveRoot*") { return '' }

    $target = Join-Path $OneDriveRoot $FolderName
    if ($WhatIfOnly) {
        return "would redirect $FolderName to '$target' (LogOnly)"
    }

    $result = Merge-FolderContent -Source $current -Destination $target -Tag $env:COMPUTERNAME
    if (-not (Set-KnownFolderRedirect -HivePath $HivePath -ValueName $valueName -NewPath $target)) {
        return "moved $($result.Moved) item(s) from $FolderName but could not update the folder location"
    }
    $detail = "redirected $FolderName to OneDrive, moved $($result.Moved) item(s)"
    if ($result.Renamed -gt 0) { $detail = "$detail, $($result.Renamed) renamed to avoid a clash" }
    if ($result.Duplicate -gt 0) { $detail = "$detail, $($result.Duplicate) already in OneDrive" }
    if ($result.Failed -gt 0) { $detail = "$detail, $($result.Failed) could not be moved" }
    return $detail
}

function Invoke-ProfileFolderRedirection {
    <#
    .SYNOPSIS
        Redirects the configured folders into OneDrive for one profile. Skipped
        entirely while that account has a session open, since moving folders out from
        under a signed-in user would break anything holding a file there.

        Unlike dehydration this is not limited to stale profiles: the accounts that
        accumulate large local folders are often the ones in daily use, which are
        exactly the profiles staleness protects.
    .PARAMETER Profile
        The Win32_UserProfile CIM instance.
    .PARAMETER Config
        The effective config.
    .PARAMETER Sessions
        The session list from Get-InteractiveSessions.
    .PARAMETER Label
        The account's display label, for logging.
    .OUTPUTS
        [String] a description of what happened, or '' when nothing applied.
    #>
    param(
        [Parameter(Mandatory)][Object]$Profile,
        [Parameter(Mandatory)][Object]$Config,
        [Object[]]$Sessions = @(),
        [Parameter(Mandatory)][String]$Label
    )
    $folders = @($Config.RedirectFolders | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    if ($folders.Count -eq 0 -or -not $Profile.LocalPath) { return '' }
    if (Test-SidHasInteractiveSession -Sid $Profile.SID -Sessions $Sessions) {
        return 'skipped folder redirection: the account is signed in'
    }

    $hive = Mount-UserProfileHive -Sid $Profile.SID -LocalPath $Profile.LocalPath
    if ($null -eq $hive) { return 'skipped folder redirection: could not read the account settings' }

    try {
        $oneDriveRoot = Get-OneDriveRootFromHive -HivePath $hive.Path
        if (-not $oneDriveRoot) { return 'skipped folder redirection: OneDrive is not set up for this account' }

        $messages = foreach ($folder in $folders) {
            $outcome = Invoke-KnownFolderRedirect -FolderName $folder -HivePath $hive.Path -ProfilePath $Profile.LocalPath -OneDriveRoot $oneDriveRoot -WhatIfOnly $Config.LogOnly
            if ($outcome) { $outcome }
        }
        $detail = ($messages -join '; ')
        if ($detail) { Write-CleanupLog -Message "Folder redirection for '$Label': $detail." }
        return $detail
    } finally {
        # Only unload what this run loaded: a hive that was already present belongs to
        # something else, and pulling it out from under that would break it.
        if ($hive.Mounted) {
            & reg.exe unload "HKU\$($Profile.SID)" 2>&1 | Out-Null
        }
    }
}

function Dismount-UserProfileHive {
    <#
    .SYNOPSIS
        Unloads a profile's registry hive (reg.exe unload HKU\<SID>), so a profile
        whose hive is still mounted can be deleted. Only ever called for a profile
        that is not untouchable (see Test-ProfileIsUntouchable) and after any session
        it owns has been logged off.
    .PARAMETER Sid
        The profile's SID, which is also its key name under HKU.
    .PARAMETER Label
        The account's display label, for logging only.
    .OUTPUTS
        [bool] $true if reg.exe reported success.
    #>
    param(
        [Parameter(Mandatory)][String]$Sid,
        [Parameter(Mandatory)][String]$Label
    )
    try {
        & reg.exe unload "HKU\$Sid" 2>&1 | Out-Null
        if ($LASTEXITCODE -eq 0) {
            Write-CleanupLog -Message "Unloaded registry hive HKU\$Sid ('$Label')."
            return $true
        }
        Write-CleanupLog -Severity Warning -Message "reg.exe could not unload hive HKU\$Sid ('$Label') (exit $LASTEXITCODE); it is probably still in use."
        return $false
    } catch {
        Write-CleanupLog -Severity Warning -Message "Failed to unload hive HKU\$Sid ('$Label'): $_"
        return $false
    }
}

function Test-DehydrationEligible {
    <#
    .SYNOPSIS
        Determines whether a profile qualifies for OneDrive dehydration: Dehydrate
        enabled, the profile is one this run is keeping, and nobody is signed into it.

        Deliberately the profiles that are staying, not the stale ones. A stale profile
        is going to be deleted, so evicting its local copies first reclaims nothing that
        deleting it would not have reclaimed anyway - the space worth reclaiming sits in
        the accounts still in use, which are exactly the ones staleness protects.

        A live session is the one hard stop: dehydrating underneath a signed-in user
        would evict files they may have open.
    .PARAMETER Config
        The effective config.
    .PARAMETER IsKept
        Whether this run is keeping the profile rather than deleting it.
    .PARAMETER HasSession
        Whether the account currently has an interactive session.
    .OUTPUTS
        [bool]
    #>
    param(
        [Parameter(Mandatory)][Object]$Config,
        [Parameter(Mandatory)][Bool]$IsKept,
        [Parameter(Mandatory)][Bool]$HasSession
    )
    return ($Config.Dehydrate -and $IsKept -and -not $HasSession)
}

function New-ProfileDetailEntry {
    <#
    .SYNOPSIS
        Builds one Details array entry for the log/notification payload.
    .PARAMETER DeviceName
        This device's name.
    .PARAMETER Label
        The profile's bare account label.
    .PARAMETER AgeLabel
        Human-readable "last used" label (see Get-ProfileAgeInfo).
    .PARAMETER SizeMB
        The profile's on-disk size in MB before dehydration, or $null.
    .PARAMETER SizeMBAfter
        The on-disk size after dehydration. Equals SizeMB when nothing was dehydrated,
        which is every run while Dehydrate is off.
    .PARAMETER TopFolders
        The profile's largest folders, one per line; empty unless it is over the
        TopFolderMinMB threshold.
    .PARAMETER DehydratableMB
        What dehydration could still release from this profile.
    .PARAMETER Action
        What happened to this profile this run.
    .PARAMETER IsCandidate
        Whether this profile is stale and unprotected - i.e. one this run would have
        deleted, did delete, or tried to. Carried as its own field so consumers can
        split the list without parsing the Action text.
    .PARAMETER OneDriveDetail
        OneDrive dehydration detail string (empty if not applicable).
    .PARAMETER DownloadsPurgeDetail
        Downloads-purge detail string (empty if not applicable).
    .PARAMETER DownloadsFreedMB
        Space actually released by emptying this profile's Downloads folder.
    .PARAMETER FolderRedirect
        Known-folder redirection detail (empty if not applicable).
    .PARAMETER BrowserCacheDetail
        Browser cache cleanup detail (empty if not applicable).
    .PARAMETER BrowserCacheFreedMB
        Space released by clearing browser caches.
    .PARAMETER BrowserCacheFreeableMB
        Space browser caches still hold that clearing them would release.
    .PARAMETER Signals
        The raw last-used signals for this profile (see Format-ProfileSignals), so a
        wrong age can be traced to its cause from the report alone.
    .OUTPUTS
        [pscustomobject] one Details array entry.
    #>
    param(
        [Parameter(Mandatory)][String]$DeviceName,
        [Parameter(Mandatory)][String]$Label,
        [Parameter(Mandatory)][String]$AgeLabel,
        $SizeMB,
        $SizeMBAfter,
        [String]$TopFolders = '',
        $DehydratableMB = 0,
        [Parameter(Mandatory)][String]$Action,
        [Bool]$IsCandidate = $false,
        [String]$OneDriveDetail = '',
        [String]$DownloadsPurgeDetail = '',
        $DownloadsFreedMB = 0,
        [String]$FolderRedirect = '',
        [String]$BrowserCacheDetail = '',
        $BrowserCacheFreedMB = 0,
        $BrowserCacheFreeableMB = 0,
        [String]$Signals = ''
    )
    [pscustomobject]@{
        DeviceName     = $DeviceName
        Profile        = $Label
        # Always a number, never null: a null here fails the notification endpoint's
        # schema validation, which would break reporting entirely whenever sizes are
        # not measured. 0 means "not measured".
        SizeMB         = if ($null -ne $SizeMB) { $SizeMB } else { 0 }
        SizeMBAfter    = if ($null -ne $SizeMBAfter) { $SizeMBAfter } elseif ($null -ne $SizeMB) { $SizeMB } else { 0 }
        LastUsed       = $AgeLabel
        TopFolders     = $TopFolders
        DehydratableMB = if ($null -ne $DehydratableMB) { $DehydratableMB } else { 0 }
        Action         = $Action
        IsCandidate    = $IsCandidate
        OneDrive       = $OneDriveDetail
        DownloadsPurge = $DownloadsPurgeDetail
        DownloadsFreedMB = if ($null -ne $DownloadsFreedMB) { $DownloadsFreedMB } else { 0 }
        FolderRedirect = $FolderRedirect
        BrowserCache   = $BrowserCacheDetail
        BrowserCacheFreedMB = if ($null -ne $BrowserCacheFreedMB) { $BrowserCacheFreedMB } else { 0 }
        BrowserCacheFreeableMB = if ($null -ne $BrowserCacheFreeableMB) { $BrowserCacheFreeableMB } else { 0 }
        Signals        = $Signals
    }
}

function Remove-StaleProfile {
    <#
    .SYNOPSIS
        Deletes a profile with Remove-CimInstance (not a raw folder delete). If that
        fails because the profile is in use, escalates - force-logs-off the SID's
        session, unloads its registry hive, retries once. Not Invoke-CimMethod
        -MethodName Delete: Win32_UserProfile has no Delete method, only ChangeOwner.
        Callers must only pass profiles that are not untouchable (see
        Test-ProfileIsUntouchable).
    .PARAMETER Profile
        The Win32_UserProfile CIM instance to delete.
    .PARAMETER Label
        The account's display label, for logging only.
    .PARAMETER Sessions
        The session list from Get-InteractiveSessions.
    .OUTPUTS
        [pscustomobject] { Success (bool); ErrorMessage (string, $null on success);
        Escalated (bool) }
    #>
    param(
        [Parameter(Mandatory)][Object]$Profile,
        [Parameter(Mandatory)][String]$Label,
        [Object[]]$Sessions = @()
    )

    try {
        Remove-CimInstance -InputObject $Profile -ErrorAction Stop
        return [pscustomobject]@{ Success = $true; ErrorMessage = $null; Escalated = $false }
    } catch {
        $firstError = $_.ToString()
    }

    Write-CleanupLog -Severity Warning -Message "First delete attempt for '$Label' failed ($firstError); escalating (logoff + hive unload) and retrying."

    if (Test-SidHasInteractiveSession -Sid $Profile.SID -Sessions $Sessions) {
        if (Invoke-ForceLogoff -Sid $Profile.SID -Label $Label -Sessions $Sessions) {
            Start-Sleep -Seconds 5
        }
    }
    if ($Profile.Loaded) {
        $null = Dismount-UserProfileHive -Sid $Profile.SID -Label $Label
    }

    try {
        Remove-CimInstance -InputObject $Profile -ErrorAction Stop
        Write-CleanupLog -Message "Delete of '$Label' succeeded after escalation."
        return [pscustomobject]@{ Success = $true; ErrorMessage = $null; Escalated = $true }
    } catch {
        return [pscustomobject]@{ Success = $false; ErrorMessage = $_.ToString(); Escalated = $true }
    }
}

function Invoke-ProfileEvaluation {
    <#
    .SYNOPSIS
        Evaluates and acts on a single profile: resolves its identity, handles its
        Downloads folder, decides whether to keep or delete it (dehydrating OneDrive
        content when eligible and not deleted), logs the outcome, and builds its
        Details entry. The single per-profile orchestrator the main loop calls.
    .PARAMETER Profile
        The Win32_UserProfile CIM instance.
    .PARAMETER Config
        The effective config.
    .PARAMETER Now
        The current time, for age calculation.
    .PARAMETER DeviceName
        This device's name, for the Details entry.
    .PARAMETER RecentSids
        The most-recently-used SIDs, newest first (see Get-RecentlyUsedSids).
    .PARAMETER DownloadsPurgeSids
        Resolved Downloads-purge target SIDs.
    .PARAMETER Sessions
        The session list from Get-InteractiveSessions.
    .OUTPUTS
        [pscustomobject] { Kept; Candidate; Deleted; Errored (all bool); DetailEntry }
    #>
    param(
        [Parameter(Mandatory)][Object]$Profile,
        [Parameter(Mandatory)][Object]$Config,
        [Parameter(Mandatory)][DateTime]$Now,
        [Parameter(Mandatory)][String]$DeviceName,
        [String[]]$RecentSids = @(),
        [Parameter(Mandatory)][Object]$DownloadsPurgeSids,
        [Object[]]$Sessions = @()
    )

    $result = [pscustomobject]@{
        Kept        = $false
        Candidate   = $false
        Deleted     = $false
        Errored     = $false
        DetailEntry = $null
    }

    $sid = $Profile.SID
    $identity = Resolve-ProfileIdentity -Sid $sid
    $label = $identity.Label

    # Single guard for every forceful action (logoff, hive unload, dehydration).
    $isExcluded = [bool](Get-ProfileExclusionReason -Sid $sid -AccountName $identity.AccountName -Config $Config)
    $isUntouchable = Test-ProfileIsUntouchable -Sid $sid -RecentSids $RecentSids -IsExcluded $isExcluded

    $isDownloadsPurgeTarget = Test-DownloadsPurgeTarget -Sid $sid -Label $label -PurgeSids $DownloadsPurgeSids -PurgeUsernames $Config.DownloadsPurgeUsernames
    $downloads = Invoke-DownloadsHandling -Profile $Profile -Label $label -IsPurgeTarget $isDownloadsPurgeTarget -ScanDownloads $Config.ScanDownloads -Sessions $Sessions -IsUntouchable $isUntouchable
    $downloadsPurgeDetail = $downloads.Detail
    $downloadsFreedMB = [Math]::Round($downloads.FreedBytes / 1MB, 1)

    $redirectDetail = Invoke-ProfileFolderRedirection -Profile $Profile -Config $Config -Sessions $Sessions -Label $label
    $browserCache = Invoke-ProfileBrowserCacheCleanup -Profile $Profile -Config $Config -Sessions $Sessions -Label $label
    $browserCacheFreedMB = [Math]::Round($browserCache.FreedBytes / 1MB, 1)
    $browserCacheFreeableMB = [Math]::Round($browserCache.FreeableBytes / 1MB, 1)

    $lastUsed = Get-ProfileLastUsed -Profile $Profile -Sessions $Sessions -Now $Now -ActivityPaths $Config.ActivityPaths
    $ageInfo = Get-ProfileAgeInfo -LastUsed $lastUsed.LastUsed -Source $lastUsed.Source -Now $Now
    $sizeInfo = Get-ProfileSizeInfo -LocalPath $Profile.LocalPath -IncludeProfileSize $Config.IncludeProfileSize -TopFolderCount $Config.TopFolderCount -TopFolderMinMB $Config.TopFolderMinMB -AdditionalDehydrateFolders $Config.AdditionalDehydrateFolders
    $keepReason = Get-ProfileKeepReason -Profile $Profile -Sid $sid -AccountName $identity.AccountName -RecentSids $RecentSids -Config $Config -AgeDays $ageInfo.AgeDays
    # Decided after the keep/delete verdict, because dehydration follows it: the
    # profiles worth reclaiming from are the ones staying, not the ones going.
    $dehydrationEligible = Test-DehydrationEligible -Config $Config -IsKept ([bool]$keepReason) -HasSession (Test-SidHasInteractiveSession -Sid $Profile.SID -Sessions $Sessions)

    if ($keepReason) {
        $severity = if ($null -eq $ageInfo.AgeDays) { 'Warning' } else { 'Info' }
        Write-CleanupLog -Severity $severity -Message "Keeping '$label' (last used: $($ageInfo.AgeLabel), size: $($sizeInfo.SizeLabel)): $keepReason. [$($lastUsed.Signals)]"
        $result.Kept = $true
        $dehydration = Invoke-ProfileDehydrationIfEligible -Profile $Profile -Config $Config -Eligible $dehydrationEligible -Label $label
        $oneDriveDetail = $dehydration.Detail
        $sizeMBAfter = if ($null -ne $dehydration.SizeMBAfter) { $dehydration.SizeMBAfter } else { $sizeInfo.SizeMB }
        $result.DetailEntry = New-ProfileDetailEntry -DeviceName $DeviceName -Label $label -AgeLabel $ageInfo.AgeLabel -SizeMB $sizeInfo.SizeMB -TopFolders $sizeInfo.TopFolders -DehydratableMB $sizeInfo.DehydratableMB -SizeMBAfter $sizeMBAfter -Action "Kept - $keepReason" -OneDriveDetail $oneDriveDetail -DownloadsPurgeDetail $downloadsPurgeDetail -DownloadsFreedMB $downloadsFreedMB -FolderRedirect $redirectDetail -BrowserCacheDetail $browserCache.Detail -BrowserCacheFreedMB $browserCacheFreedMB -BrowserCacheFreeableMB $browserCacheFreeableMB -Signals $lastUsed.Signals
        return $result
    }

    $result.Candidate = $true
    if ($Config.LogOnly) {
        Write-CleanupLog -Message "Would delete '$label' (last used: $($ageInfo.AgeLabel), size: $($sizeInfo.SizeLabel)). LogOnly is enabled - no action taken."
        $dehydration = Invoke-ProfileDehydrationIfEligible -Profile $Profile -Config $Config -Eligible $dehydrationEligible -Label $label
        $oneDriveDetail = $dehydration.Detail
        $sizeMBAfter = if ($null -ne $dehydration.SizeMBAfter) { $dehydration.SizeMBAfter } else { $sizeInfo.SizeMB }
        $result.DetailEntry = New-ProfileDetailEntry -DeviceName $DeviceName -Label $label -AgeLabel $ageInfo.AgeLabel -SizeMB $sizeInfo.SizeMB -TopFolders $sizeInfo.TopFolders -DehydratableMB $sizeInfo.DehydratableMB -SizeMBAfter $sizeMBAfter -Action 'Would delete (LogOnly)' -IsCandidate $true -OneDriveDetail $oneDriveDetail -DownloadsPurgeDetail $downloadsPurgeDetail -DownloadsFreedMB $downloadsFreedMB -FolderRedirect $redirectDetail -BrowserCacheDetail $browserCache.Detail -BrowserCacheFreedMB $browserCacheFreedMB -BrowserCacheFreeableMB $browserCacheFreeableMB -Signals $lastUsed.Signals
        return $result
    }

    Write-CleanupLog -Message "Deleting '$label' (last used: $($ageInfo.AgeLabel), size: $($sizeInfo.SizeLabel))."
    $deletion = Remove-StaleProfile -Profile $Profile -Label $label -Sessions $Sessions
    if ($deletion.Success) {
        $result.Deleted = $true
        # No dehydration here even if eligible - the profile is gone, nothing to reclaim.
        $result.DetailEntry = New-ProfileDetailEntry -DeviceName $DeviceName -Label $label -AgeLabel $ageInfo.AgeLabel -SizeMB $sizeInfo.SizeMB -TopFolders $sizeInfo.TopFolders -DehydratableMB $sizeInfo.DehydratableMB -SizeMBAfter $sizeInfo.SizeMB -Action 'Deleted' -IsCandidate $true -DownloadsPurgeDetail $downloadsPurgeDetail -DownloadsFreedMB $downloadsFreedMB -FolderRedirect $redirectDetail -BrowserCacheDetail $browserCache.Detail -BrowserCacheFreedMB $browserCacheFreedMB -BrowserCacheFreeableMB $browserCacheFreeableMB -Signals $lastUsed.Signals
    } else {
        Write-CleanupLog -Severity Error -Message "Failed to delete '$label': $($deletion.ErrorMessage)"
        $result.Errored = $true
        $dehydration = Invoke-ProfileDehydrationIfEligible -Profile $Profile -Config $Config -Eligible $dehydrationEligible -Label $label
        $oneDriveDetail = $dehydration.Detail
        $sizeMBAfter = if ($null -ne $dehydration.SizeMBAfter) { $dehydration.SizeMBAfter } else { $sizeInfo.SizeMB }
        $result.DetailEntry = New-ProfileDetailEntry -DeviceName $DeviceName -Label $label -AgeLabel $ageInfo.AgeLabel -SizeMB $sizeInfo.SizeMB -TopFolders $sizeInfo.TopFolders -DehydratableMB $sizeInfo.DehydratableMB -SizeMBAfter $sizeMBAfter -Action "Delete failed: $($deletion.ErrorMessage)" -IsCandidate $true -OneDriveDetail $oneDriveDetail -DownloadsPurgeDetail $downloadsPurgeDetail -DownloadsFreedMB $downloadsFreedMB -FolderRedirect $redirectDetail -BrowserCacheDetail $browserCache.Detail -BrowserCacheFreedMB $browserCacheFreedMB -BrowserCacheFreeableMB $browserCacheFreeableMB -Signals $lastUsed.Signals
    }
    return $result
}
#endregion

#region Run orchestration
function Resolve-DownloadsPurgeSids {
    <#
    .SYNOPSIS
        Resolves each configured Downloads-purge UPN to a local SID and logs the
        outcome - the complement to DownloadsPurgeUsernames matching, so a purge
        target is still found even if its account name has changed.
    .PARAMETER Upns
        The DownloadsPurgeUpns list from config.
    .OUTPUTS
        A case-insensitive [System.Collections.Generic.HashSet[string]] of resolved SIDs.
    #>
    param([String[]]$Upns = @())

    $sids = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($upn in $Upns) {
        $resolved = Resolve-UpnToSid -Upn $upn
        if ($resolved) {
            $null = $sids.Add($resolved)
            Write-CleanupLog -Message "Resolved Downloads-purge target '$upn' to SID '$resolved'."
        } else {
            Write-CleanupLog -Severity Warning -Message "Could not resolve Downloads-purge target '$upn' to a local SID on this device (never signed in here?) - falling back to DownloadsPurgeUsernames matching only for this entry."
        }
    }
    return $sids
}

function Get-NonSpecialUserProfiles {
    <#
    .SYNOPSIS
        Enumerates every non-Special Win32_UserProfile on this device (excludes
        SYSTEM/LocalService/NetworkService/Default/Public/defaultuser0/etc., which
        Windows itself flags as Special).
    .OUTPUTS
        An array of CIM profile instances, or $null if enumeration itself failed
        (the specific reason is logged internally).
    #>
    try {
        return @(Get-CimInstance -ClassName Win32_UserProfile -ErrorAction Stop | Where-Object { -not $_.Special })
    } catch {
        Write-CleanupLog -Severity Error -Message "Failed to enumerate user profiles: $_. Aborting run."
        return $null
    }
}

function Get-RecentlyUsedSids {
    <#
    .SYNOPSIS
        Finds and logs the SIDs of the N most recently used profiles, newest first,
        ranked by the resolved last-used time (Get-ProfileLastUsed) rather than
        LastUseTime. These are protected from deletion and every forceful action.

        Profiles already excluded by config are skipped when ranking. They are kept
        regardless, so letting them occupy a slot would spend the protection on a
        profile that does not need it while leaving a real user unprotected - which is
        what happened when two service accounts held both slots on a live device.
    .PARAMETER Profiles
        The profiles to consider.
    .PARAMETER Sessions
        The session list from Get-InteractiveSessions; a signed-in user ranks first.
    .PARAMETER Now
        The current time.
    .PARAMETER Count
        How many to protect (ProtectedRecentUsers from the config).
    .PARAMETER ActivityPaths
        Folders treated as user activity (ActivityPaths from the config).
    .PARAMETER Config
        The effective config, for the exclusion lists.
    .OUTPUTS
        [String[]] the SIDs, newest first; empty if no profile has a usable timestamp.
    #>
    param(
        [Parameter(Mandatory)][Object[]]$Profiles,
        [Object[]]$Sessions = @(),
        [Parameter(Mandatory)][DateTime]$Now,
        [Int32]$Count = 2,
        [String[]]$ActivityPaths = @(),
        [Object]$Config = $null
    )

    if ($Count -lt 1) {
        Write-CleanupLog -Severity Warning -Message "ProtectedRecentUsers is $Count; no profile will be protected by recency this run."
        return
    }

    $ranked = @($Profiles | ForEach-Object {
        $identity = Resolve-ProfileIdentity -Sid $_.SID
        if ($Config -and (Get-ProfileExclusionReason -Sid $_.SID -AccountName $identity.AccountName -Config $Config)) {
            return
        }
        $resolved = Get-ProfileLastUsed -Profile $_ -Sessions $Sessions -Now $Now -ActivityPaths $ActivityPaths
        if ($resolved.LastUsed) {
            [pscustomobject]@{ Sid = $_.SID; LastUsed = $resolved.LastUsed; Source = $resolved.Source }
        }
    } | Sort-Object -Property LastUsed -Descending | Select-Object -First $Count)

    $sids = @($ranked | Select-Object -ExpandProperty Sid)
    if ($sids.Count -gt 0) {
        $summary = for ($i = 0; $i -lt $ranked.Count; $i++) { "$($i + 1). $($ranked[$i].Sid) [$($ranked[$i].LastUsed.ToString('yyyy-MM-dd')) via $($ranked[$i].Source)]" }
        Write-CleanupLog -Message "Protected by recency ($($sids.Count) of $Count requested): $($summary -join ', '). These are never deleted, logged off, or otherwise disturbed."
    } else {
        Write-CleanupLog -Severity Warning -Message 'No profile has a usable last-used timestamp; recency protection is unavailable for this run.'
    }
    # Emitted (not "return ,$sids") so the caller's @(...) collects a flat string list;
    # wrapping with the comma operator here would nest the array one level deeper.
    $sids
}

function Limit-DetailFolderLines {
    <#
    .SYNOPSIS
        Trims folder lists so a device with many profiles cannot push the Teams card
        past its size limit. Adaptive depth makes each line longer, and the card
        carries every profile's list, so the two multiply: at the 25-profile cap an
        untrimmed report lands within a few percent of the limit, where the card
        silently fails to post.

        Shares one budget across the report rather than a fixed count per profile,
        so a device with few profiles still gets the full list.

        Edits the entries in place and returns nothing, deliberately: returning an
        array of one element unwraps it back to a bare object, which has already
        caused one reporting bug here.
    .PARAMETER Details
        The Details entries to trim.
    .PARAMETER MaxTotalLines
        Total folder lines allowed across the whole report.
    .PARAMETER MinLinesPerProfile
        Never trim a profile below this many lines, however many profiles there are.
    .OUTPUTS
        None. Details entries are modified in place.
    #>
    param(
        [Object[]]$Details = @(),
        [Int32]$MaxTotalLines = 100,
        [Int32]$MinLinesPerProfile = 3
    )
    if ($Details.Count -eq 0) { return }
    $allowed = [Math]::Max($MinLinesPerProfile, [Math]::Floor($MaxTotalLines / $Details.Count))
    foreach ($detail in $Details) {
        if (-not $detail.TopFolders) { continue }
        $lines = $detail.TopFolders -split "`n"
        if ($lines.Count -gt $allowed) {
            $detail.TopFolders = (($lines | Select-Object -First $allowed) -join "`n")
        }
    }
}

function Get-ReclaimableMB {
    <#
    .SYNOPSIS
        Totals every megabyte this run frees or would free on the device, from all
        three sources rather than profile deletion alone:

          - stale profiles, the space deleting them recovers
          - Downloads folders emptied on purge-target accounts
          - browser caches: what clearing them released, or what they still hold
          - dehydration: what it released, or on a profile it did not run for, what
            it could still release

        Counting what dehydration *could* do matters because otherwise the figure is
        zero for it on every run while Dehydrate is off, which hides the opportunity
        entirely - the reason for reporting it at all.

        Nothing is counted twice. Downloads are emptied before the profile is
        measured, so those bytes have already left SizeMB. Dehydration happens after
        and is exactly what SizeMBAfter records. A profile being deleted contributes
        its whole size and nothing further, since deleting it takes the dehydratable
        content with it.
    .PARAMETER Details
        The full per-profile Details array for this run.
    .OUTPUTS
        [Double] total MB freed or reclaimable; 0 when there is nothing.
    #>
    param([Object[]]$Details = @())
    $total = [Double]0
    foreach ($detail in $Details) {
        if ($null -ne $detail.DownloadsFreedMB) {
            $total += [Double]$detail.DownloadsFreedMB
        }
        if ($null -ne $detail.BrowserCacheFreedMB) {
            $total += [Double]$detail.BrowserCacheFreedMB
        }

        if ($detail.IsCandidate) {
            # Deleting takes the whole profile - dehydratable content and uncleared
            # caches included - so its size already covers everything and must not be
            # counted twice.
            if ($null -ne $detail.SizeMB) { $total += [Double]$detail.SizeMB }
            continue
        }

        $dehydrated = 0
        if ($null -ne $detail.SizeMB -and $null -ne $detail.SizeMBAfter) {
            $dehydrated = [Double]$detail.SizeMB - [Double]$detail.SizeMBAfter
        }
        if ($null -ne $detail.BrowserCacheFreeableMB) {
            # Caches still in place on a profile that is staying: their bytes are still
            # inside SizeMB, which is not counted for a kept profile, so adding them
            # here is the only place they appear.
            $total += [Double]$detail.BrowserCacheFreeableMB
        }
        if ($dehydrated -gt 0) {
            # Dehydration ran: count what it actually released.
            $total += $dehydrated
        } elseif ($null -ne $detail.DehydratableMB) {
            # It did not, so count what it would release - the figure is otherwise
            # always zero while Dehydrate is off, which hides the whole opportunity.
            $total += [Double]$detail.DehydratableMB
        }
    }
    return [Math]::Round($total, 1)
}

function Get-NotificationSummary {
    <#
    .SYNOPSIS
        Builds the top-level JSON summary object sent to the notification webhook,
        capping Details to 25 entries so an unusually large profile count can't
        produce a huge payload (the log file always has the full list regardless).
    .PARAMETER Config
        The effective config.
    .PARAMETER DeviceName
        This device's name.
    .PARAMETER ProfilesEvaluated
        Total profiles evaluated this run.
    .PARAMETER Kept
        Count of profiles kept.
    .PARAMETER Candidates
        Count of stale, non-protected candidates.
    .PARAMETER Deleted
        Count actually deleted.
    .PARAMETER Errors
        Count of failed delete attempts.
    .PARAMETER NotifyDetails
        The full per-profile Details array for this run.
    .OUTPUTS
        [pscustomobject] the summary object, ready for Send-CleanupNotification.
    #>
    param(
        [Parameter(Mandatory)][Object]$Config,
        [Parameter(Mandatory)][String]$DeviceName,
        [Parameter(Mandatory)][Int32]$ProfilesEvaluated,
        [Parameter(Mandatory)][Int32]$Kept,
        [Parameter(Mandatory)][Int32]$Candidates,
        [Parameter(Mandatory)][Int32]$Deleted,
        [Parameter(Mandatory)][Int32]$Errors,
        [Object[]]$NotifyDetails = @()
    )
    $cappedDetails = @($NotifyDetails | Select-Object -First 25)
    Limit-DetailFolderLines -Details $cappedDetails
    # Totalled over the full list, not the capped one, so a truncated report still
    # states the real reclaimable figure.
    $reclaimableMB = Get-ReclaimableMB -Details $NotifyDetails
    $summary = [pscustomobject]@{
        DeviceName        = $DeviceName
        Version           = if ([string]::IsNullOrWhiteSpace($Config.Version)) { 'Unknown' } else { $Config.Version }
        RunTime           = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
        RunTimeUtc        = (Get-Date).ToUniversalTime().ToString('yyyy-MM-dd HH:mm:ss')
        RetentionDays     = $Config.RetentionDays
        LogOnly           = $Config.LogOnly
        ProfilesEvaluated = $ProfilesEvaluated
        Kept              = $Kept
        Candidates        = $Candidates
        Deleted           = $Deleted
        Errors            = $Errors
        ReclaimableMB     = $reclaimableMB
        DetailsTruncated  = ($NotifyDetails.Count -gt $cappedDetails.Count)
        Details           = $cappedDetails
    }
    return $summary
}

function Invoke-RunNotification {
    <#
    .SYNOPSIS
        Decides whether to send a run notification - skipped entirely if no webhook
        is configured, or if NotifyOnlyIfActionable is on and nothing actionable
        happened this run - and sends it (Get-NotificationSummary + Send-CleanupNotification)
        otherwise.
    .PARAMETER Config
        The effective config.
    .PARAMETER DeviceName
        This device's name.
    .PARAMETER ProfilesEvaluated
        Total profiles evaluated this run.
    .PARAMETER Kept
        Count of profiles kept.
    .PARAMETER Candidates
        Count of stale, non-protected candidates.
    .PARAMETER Deleted
        Count actually deleted.
    .PARAMETER Errors
        Count of failed delete attempts.
    .PARAMETER NotifyDetails
        The full per-profile Details array for this run.
    .OUTPUTS
        None.
    #>
    param(
        [Parameter(Mandatory)][Object]$Config,
        [Parameter(Mandatory)][String]$DeviceName,
        [Parameter(Mandatory)][Int32]$ProfilesEvaluated,
        [Parameter(Mandatory)][Int32]$Kept,
        [Parameter(Mandatory)][Int32]$Candidates,
        [Parameter(Mandatory)][Int32]$Deleted,
        [Parameter(Mandatory)][Int32]$Errors,
        [Object[]]$NotifyDetails = @()
    )
    if ([string]::IsNullOrWhiteSpace($Config.NotificationWebhookUrl)) { return }

    if ($Config.NotifyOnlyIfActionable -and $Candidates -eq 0 -and $Errors -eq 0) {
        Write-CleanupLog -Message 'Skipping notification: NotifyOnlyIfActionable is enabled and nothing actionable this run.'
        return
    }

    $summary = Get-NotificationSummary -Config $Config -DeviceName $DeviceName -ProfilesEvaluated $ProfilesEvaluated -Kept $Kept -Candidates $Candidates -Deleted $Deleted -Errors $Errors -NotifyDetails $NotifyDetails
    Send-CleanupNotification -WebhookUrl $Config.NotificationWebhookUrl -Summary $summary
}
#endregion

#region Main
Write-CleanupLog -Message '--- Profile cleanup run started ---'

$config = Get-CleanupConfig -Path $ConfigPath
Write-CleanupLog -Message "Config: RetentionDays=$($config.RetentionDays), LogOnly=$($config.LogOnly), ProtectedRecentUsers=$($config.ProtectedRecentUsers), ExcludedSids=$($config.ExcludedSids.Count), ExcludedUsernames=$($config.ExcludedUsernames.Count)."

$downloadsPurgeSids = Resolve-DownloadsPurgeSids -Upns $config.DownloadsPurgeUpns

# Enumerated once per run and reused for every profile: identifies who is actually
# signed in (by SID) and which Windows session each one owns.
$interactiveSessions = @(Get-InteractiveSessions)
if ($interactiveSessions.Count -gt 0) {
    Write-CleanupLog -Message "Interactive session(s) detected: $(($interactiveSessions | ForEach-Object { "$($_.Sid) (session $($_.SessionId))" }) -join ', ')."
} else {
    Write-CleanupLog -Message 'No interactive sessions detected; nobody is signed in right now.'
}

$profileScanResult = Get-NonSpecialUserProfiles
if ($null -eq $profileScanResult) {
    Write-CleanupLog -Message '--- Profile cleanup run finished ---'
    return
}
# Re-wrapped here, not just inside Get-NonSpecialUserProfiles: a function's own
# "return @(...)" still unwraps back to a lone scalar across the call boundary when
# it has exactly one element, which made $allProfiles.Count silently read as $null
# (then 0, via the Mandatory [Int32] parameter it's passed into) on any single-profile
# device - despite that profile still being evaluated correctly.
$allProfiles = @($profileScanResult)
if ($allProfiles.Count -eq 0) {
    Write-CleanupLog -Message 'No non-special user profiles found. Nothing to do.'
    Write-CleanupLog -Message '--- Profile cleanup run finished ---'
    return
}

$deviceName = $env:COMPUTERNAME
$now = Get-Date
$recentSids = @(Get-RecentlyUsedSids -Profiles $allProfiles -Sessions $interactiveSessions -Now $now -Count $config.ProtectedRecentUsers -ActivityPaths $config.ActivityPaths -Config $config)

$kept = 0
$candidates = 0
$deleted = 0
$errors = 0
$notifyDetails = @()

foreach ($profile in $allProfiles) {
    $evaluation = Invoke-ProfileEvaluation -Profile $profile -Config $config -Now $now -DeviceName $deviceName -RecentSids $recentSids -DownloadsPurgeSids $downloadsPurgeSids -Sessions $interactiveSessions

    if ($evaluation.Kept) { $kept++ }
    if ($evaluation.Candidate) { $candidates++ }
    if ($evaluation.Deleted) { $deleted++ }
    if ($evaluation.Errored) { $errors++ }
    $notifyDetails += $evaluation.DetailEntry
}

Write-CleanupLog -Message "Summary: $($allProfiles.Count) profile(s) evaluated, $kept kept, $candidates stale candidate(s), $deleted deleted, $errors error(s)."

Invoke-RunNotification -Config $config -DeviceName $deviceName -ProfilesEvaluated $allProfiles.Count -Kept $kept -Candidates $candidates -Deleted $deleted -Errors $errors -NotifyDetails $notifyDetails

Write-CleanupLog -Message '--- Profile cleanup run finished ---'
#endregion
