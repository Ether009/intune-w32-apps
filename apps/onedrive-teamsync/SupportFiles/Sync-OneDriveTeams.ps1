$ErrorActionPreference = 'Stop'

$TenantId = '46d9804e-e6e3-433c-a5fe-766016144275'
$ClientId = '7a8d6e5a-734c-44ce-8673-3f7c05c47421'
$CertThumbprint = '5ACD0E673C1D5DA72BB2497C37D74A7F67F7AF25'

# This script runs as SYSTEM (the AutoMountTeamSites registry path is writable only by
# SYSTEM/Administrators - a standard user, even the one this script is acting on behalf of,
# cannot write it - confirmed via a real ACL check on a real device). SYSTEM has no "current
# user" of its own, so almost everything below has to explicitly resolve and act on the actual
# interactively logged-on user instead of relying on $env:LOCALAPPDATA / HKCU / whoami, none of
# which mean anything useful under SYSTEM.

#region Resolve the interactive user (SYSTEM has none of its own)

function Get-InteractiveUserContext {
    # explorer.exe only runs in an interactive user's own session, never SYSTEM's or a service
    # session - its owner and session ID reliably identify "the person actually sitting here."
    # Returns $null rather than throwing when nobody is signed in: the hourly trigger fires
    # regardless of sessions, so "no interactive user" is a normal outcome, not an error.
    $proc = Get-CimInstance Win32_Process -Filter "Name='explorer.exe'" | Select-Object -First 1
    if (-not $proc) { return $null }
    $ownerSid = (Invoke-CimMethod -InputObject $proc -MethodName GetOwnerSid).Sid

    $profilePath = (Get-ItemProperty -LiteralPath "Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList\$ownerSid").ProfileImagePath

    return [pscustomobject]@{
        Sid           = $ownerSid
        SessionId     = [uint32]$proc.SessionId
        ProfilePath   = $profilePath
        LocalAppData  = Join-Path $profilePath 'AppData\Local'
        HkuRoot       = "Registry::HKEY_USERS\$ownerSid"
    }
}

#endregion

$UserContext = Get-InteractiveUserContext
if (-not $UserContext) {
    # Nobody signed in. There is no user whose libraries could be synced, and no per-user profile
    # to even write a log into, so there is nothing useful to record. Exit 0 rather than failing:
    # the hourly trigger runs whether or not anyone is logged on, and an overnight machine would
    # otherwise fill Task Scheduler history with failures that mean nothing.
    exit 0
}
$LogDir = Join-Path $UserContext.LocalAppData 'OneDriveTeamSync'
$LogFile = Join-Path $LogDir 'sync.log'
$SiteCacheFile = Join-Path $LogDir 'sitecache.json'
New-Item -ItemType Directory -Path $LogDir -Force | Out-Null

function Write-Log {
    param([string]$Message)
    "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') $Message" | Out-File -FilePath $LogFile -Append -Encoding UTF8
}

#region Cert-based Graph auth (app-only, no client secret). Running as SYSTEM, the cert's
# private key is accessible without any special ACL grant - LocalMachine\My is
# SYSTEM/Administrators-only by default, which is exactly what we want now.
function Get-GraphToken {
    $cert = Get-Item "Cert:\LocalMachine\My\$CertThumbprint" -ErrorAction Stop

    $now = [DateTimeOffset]::UtcNow
    $header = @{ alg = 'RS256'; typ = 'JWT'; x5t = [Convert]::ToBase64String($cert.GetCertHash()) -replace '\+','-' -replace '/','_' -replace '=' } | ConvertTo-Json -Compress
    $payload = @{
        aud = "https://login.microsoftonline.com/$TenantId/oauth2/v2.0/token"
        iss = $ClientId
        sub = $ClientId
        jti = [guid]::NewGuid().ToString()
        nbf = $now.ToUnixTimeSeconds()
        exp = $now.AddMinutes(10).ToUnixTimeSeconds()
    } | ConvertTo-Json -Compress

    $toBase64Url = {
        param($bytes)
        [Convert]::ToBase64String($bytes) -replace '\+','-' -replace '/','_' -replace '='
    }
    $headerB64 = & $toBase64Url ([Text.Encoding]::UTF8.GetBytes($header))
    $payloadB64 = & $toBase64Url ([Text.Encoding]::UTF8.GetBytes($payload))
    $unsigned = "$headerB64.$payloadB64"

    $rsa = [System.Security.Cryptography.X509Certificates.RSACertificateExtensions]::GetRSAPrivateKey($cert)
    $signature = $rsa.SignData([Text.Encoding]::UTF8.GetBytes($unsigned), [Security.Cryptography.HashAlgorithmName]::SHA256, [Security.Cryptography.RSASignaturePadding]::Pkcs1)
    $sigB64 = & $toBase64Url $signature
    $clientAssertion = "$unsigned.$sigB64"

    $body = @{
        client_id             = $ClientId
        scope                 = 'https://graph.microsoft.com/.default'
        client_assertion_type = 'urn:ietf:params:oauth:client-assertion-type:jwt-bearer'
        client_assertion      = $clientAssertion
        grant_type            = 'client_credentials'
    }
    $resp = Invoke-RestMethod -Method Post -Uri "https://login.microsoftonline.com/$TenantId/oauth2/v2.0/token" -Body $body
    return $resp.access_token
}
#endregion

#region Local JSON state (site-info cache)
function Read-JsonHashtable {
    # ConvertFrom-Json -AsHashtable is PowerShell 6+ only, and this runs under Windows PowerShell
    # 5.1 - the previous code used it inside a try/catch that swallowed the resulting error, so
    # every read silently returned an empty hashtable and nothing was ever actually remembered.
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return @{} }
    try {
        $json = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
    } catch {
        return @{}
    }
    $result = @{}
    if ($json) {
        foreach ($p in $json.PSObject.Properties) { $result[$p.Name] = $p.Value }
    }
    return $result
}

function Write-JsonHashtable {
    param([string]$Path, $Value)
    $Value | ConvertTo-Json -Depth 5 | Out-File -FilePath $Path -Encoding UTF8
}

# A group's SharePoint site and document-library ids never change once provisioned, but resolving
# them costs two Graph calls per group on every single run - by far the bulk of this script's Graph
# traffic (1 + 2N calls for N groups). Caching them locally reduces a steady-state run to just the
# token request plus the one /memberOf call that genuinely has to be fresh, which is what makes
# running this on a repeating schedule rather than only at logon reasonable.
function Get-SiteCache { Read-JsonHashtable -Path $SiteCacheFile }
function Save-SiteCache { param($Cache) Write-JsonHashtable -Path $SiteCacheFile -Value $Cache }

#endregion

#endregion

#region OneDrive AutoMountTeamSites policy state - silent add mechanism
# Verified directly against the real OneDrive.admx on this machine (not documentation alone):
#   policy AutoMountTeamSites -> list key "Software\Policies\Microsoft\OneDrive\TenantAutoMount",
#   additive, explicitValue. Each list entry is one REG_SZ value under that key: the value NAME
# is an arbitrary label (used here as the site's own GUID, so re-runs can match existing entries
# deterministically), and the value DATA is
# "tenantId={..}&siteId={..}&webId={..}&listId=..&webUrl=https://..&version=1".
# OneDrive itself picks these up on its own (next OneDrive.exe start / within its own window) -
# no window, no user interaction, unlike odopen://. Confirmed via Microsoft's own documentation
# that REMOVING an entry does NOT automatically unsync an already-synced library - this only
# replaces the add path; removal still goes through Remove-OneDriveDeepSyncState/Invoke-
# UnregisterSyncRoot in the main pass's Disconnect region.
#
# Confirmed via a real ACL check that this key is writable only by SYSTEM/Administrators, even
# for the user it's acting on behalf of - this is why this whole script runs as SYSTEM and
# operates on the target user's hive under HKEY_USERS rather than as that user directly.
function Get-AutoMountRegPath { "$($UserContext.HkuRoot)\SOFTWARE\Policies\Microsoft\OneDrive\TenantAutoMount" }

function Get-AutoMountEntries {
    $path = Get-AutoMountRegPath
    if (-not (Test-Path $path)) { return @() }
    $props = Get-ItemProperty -LiteralPath $path
    $props.PSObject.Properties |
        Where-Object { $_.Name -notmatch '^PS' } |
        ForEach-Object {
            if ($_.Value -match 'siteId=\{?([0-9a-fA-F-]+)\}?') {
                [pscustomobject]@{ ValueName = $_.Name; SiteId = $Matches[1]; Data = $_.Value }
            }
        }
}

function Set-AutoMountEntry {
    param($SiteId, $WebId, $ListId, $WebUrl, $DisplayName)
    $path = Get-AutoMountRegPath
    if (-not (Test-Path $path)) {
        New-Item -Path $path -Force | Out-Null
    }
    $data = "tenantId={$TenantId}&siteId={$SiteId}&webId={$WebId}&listId=$ListId&webUrl=$WebUrl&version=1"
    Write-Log "Setting auto-mount entry for $DisplayName (site $SiteId)"
    Set-ItemProperty -LiteralPath $path -Name $SiteId -Value $data -Type String
}

function Remove-AutoMountEntry {
    param($SiteId)
    Write-Log "Removing auto-mount entry for site $SiteId"
    Remove-ItemProperty -LiteralPath (Get-AutoMountRegPath) -Name $SiteId -ErrorAction SilentlyContinue
}
#endregion

#region Graph lookups
function Get-CurrentUserUpn {
    # whoami /upn only reflects the process's own identity (SYSTEM has none) - read it straight
    # out of the target user's own OneDrive account registration instead, matched by tenant ID
    # in case they have multiple OneDrive accounts configured. This is the same technique the
    # old tool used, which was actually the right call for a SYSTEM-context script - it just
    # wasn't SYSTEM-context before.
    $accountsPath = "$($UserContext.HkuRoot)\Software\Microsoft\OneDrive\Accounts"
    if (-not (Test-Path $accountsPath)) { throw "No OneDrive accounts found under the user's hive." }
    foreach ($account in Get-ChildItem $accountsPath) {
        $props = Get-ItemProperty $account.PSPath -ErrorAction SilentlyContinue
        if ($props.ConfiguredTenantId -eq $TenantId -and $props.UserEmail) {
            return $props.UserEmail
        }
    }
    throw "No OneDrive account configured for tenant $TenantId under the user's hive."
}

function Get-CurrentUserTeams {
    # Any Microsoft 365 Group the user belongs to, not just ones that have gone through Teams
    # provisioning - the tool was never meant to require that. Filtering on
    # resourceProvisioningOptions -contains 'Team' excluded a real group the user created and
    # was a member of, because Teams-specific provisioning is a separate, sometimes-delayed step
    # from the group (and its SharePoint site) actually existing - groupTypes -contains 'Unified'
    # is what actually distinguishes an M365 Group (has a SharePoint site) from a plain security
    # group (doesn't), independent of whether it's also been made into a Team.
    param($Token, $Upn)
    $headers = @{ Authorization = "Bearer $Token" }
    $groups = Invoke-RestMethod -Headers $headers -Uri "https://graph.microsoft.com/v1.0/users/$Upn/memberOf?`$select=id,displayName,groupTypes"
    return $groups.value | Where-Object { $_.groupTypes -contains 'Unified' }
}

function Get-TeamSiteInfo {
    param($Token, $GroupId)
    $headers = @{ Authorization = "Bearer $Token" }
    $site = Invoke-RestMethod -Headers $headers -Uri "https://graph.microsoft.com/v1.0/groups/$GroupId/sites/root"
    $lists = Invoke-RestMethod -Headers $headers -Uri "https://graph.microsoft.com/v1.0/groups/$GroupId/sites/root/lists"
    # Match by template rather than a localized display name (the original script hardcoded the
    # Swedish "Delade Dokument" name, which silently broke for any differently-configured site).
    $docLib = $lists.value | Where-Object { $_.list.template -eq 'documentLibrary' } | Select-Object -First 1
    if (-not $docLib) { return $null }

    $ids = $site.id -split ','
    return [pscustomobject]@{
        SiteId   = $ids[1]
        WebId    = $ids[2]
        ListId   = $docLib.id
        WebUrl   = $site.webUrl
    }
}

#endregion

#endregion

#region Main sync pass
try {
    Write-Log "=== Sync run starting ==="
    $token = Get-GraphToken
    $upn = Get-CurrentUserUpn
    $teams = @(Get-CurrentUserTeams -Token $token -Upn $upn)
    Write-Log "User: $upn, Teams: $($teams.Count)"

    $autoMounted = @(Get-AutoMountEntries)

    # Resolve desired state first - removals have to happen before additions so an entry cleared
    # this run can be rewritten with fresh data below rather than skipped as "already present".
    # Site/list ids come from the local cache where possible: they're fixed for the life of the
    # group, so re-fetching them every run was two Graph calls per group for data that never
    # changed. Only groups the cache hasn't seen cost anything now.
    $siteCache = Get-SiteCache
    $cacheChanged = $false
    $desired = @{}
    foreach ($team in $teams) {
        $cached = $siteCache[$team.id]
        if ($cached -and $cached.SiteId -and $cached.WebId -and $cached.ListId -and $cached.WebUrl) {
            $info = [pscustomobject]@{ SiteId = $cached.SiteId; WebId = $cached.WebId; ListId = $cached.ListId; WebUrl = $cached.WebUrl }
        } else {
            $info = Get-TeamSiteInfo -Token $token -GroupId $team.id
            if ($info) {
                $siteCache[$team.id] = @{ SiteId = $info.SiteId; WebId = $info.WebId; ListId = $info.ListId; WebUrl = $info.WebUrl; cachedAt = (Get-Date -Format 'o') }
                $cacheChanged = $true
            }
        }
        if (-not $info) { Write-Log "Skipping $($team.displayName) - no document library found"; continue }
        $desired[$info.SiteId] = [pscustomobject]@{ Info = $info; DisplayName = $team.displayName }
    }

    # Drop cache entries for groups the user is no longer in, so the file doesn't grow forever and
    # a rejoin re-resolves against Graph rather than trusting arbitrarily old ids.
    $currentGroupIds = @{}
    foreach ($team in $teams) { $currentGroupIds[$team.id] = $true }
    foreach ($cachedId in @($siteCache.Keys)) {
        if (-not $currentGroupIds.ContainsKey($cachedId)) { $siteCache.Remove($cachedId); $cacheChanged = $true }
    }
    if ($cacheChanged) { Save-SiteCache -Cache $siteCache }

    #region Removals
    # Auto-mount entries this tool previously wrote for sites the user is no longer a member of.
    # Removing the entry is the entire removal story now, and it is the part that actually matters:
    # the entry was being rewritten every run, so OneDrive kept being told to mount a library the
    # user had lost access to. It retried forever, the error never cleared, and sign-in got
    # measurably slower for every stale library - confirmed on a real device.
    #
    # What this deliberately no longer does is act on the local sync: no stopping OneDrive, no
    # unregistering the sync root, no deleting local folders, no notification. That machinery was
    # proven to work, but it could only ever run while OneDrive was stopped, so it depended on
    # either a toast button (which never renders at all from a process like this one) or on the
    # user happening to quit OneDrive during the few minutes a run was watching. Both were too
    # unreliable to build on. The user disconnects the stale library themselves, prompted by
    # OneDrive's own "can't sync" error; this just stops fighting them about it. The removed
    # implementation is in git history around v2.2.x if it is ever wanted back.
    #
    # No site-path matching is needed here (unlike the additions side): $autoMounted entries carry
    # the real SiteId this tool wrote, so they are matched against $desired directly. And because
    # this only ever touches entries the tool itself created, it cannot affect the user's personal
    # OneDrive or a private channel they synced by hand.
    foreach ($entry in $autoMounted) {
        if ($desired.ContainsKey($entry.SiteId)) { continue }
        Remove-AutoMountEntry -SiteId $entry.SiteId
    }

    #endregion

    #region Additions
    # Re-read auto-mount state in case the removals pass above cleared an entry we're about to
    # recreate below with fresh data.
    #
    # Nothing is done to make OneDrive notice sooner: it re-reads the auto-mount list on its own
    # schedule and picks new entries up within a few hours, confirmed on a real device. Writing the
    # entry is the whole job here. An earlier version also zeroed OneDrive's TimerAutoMount cooldown
    # to force an immediate check - that write silently never took effect from SYSTEM, and since the
    # library mounts on its own anyway and the latency doesn't matter, it was dropped rather than
    # fixed. Adds only have to converge eventually, not promptly - some users go a year without a
    # reboot, which is why this runs hourly rather than only at logon.
    $autoMounted = @(Get-AutoMountEntries)
    foreach ($siteId in $desired.Keys) {
        $info = $desired[$siteId].Info
        $existing = $autoMounted | Where-Object { $_.SiteId -eq $siteId }
        if ($existing) { continue }
        Set-AutoMountEntry -SiteId $info.SiteId -WebId $info.WebId -ListId $info.ListId -WebUrl $info.WebUrl -DisplayName $desired[$siteId].DisplayName
    }

    #endregion

    Write-Log "=== Sync run complete ==="
}
catch {
    Write-Log "ERROR: $($_.Exception.Message)"
}
#endregion
