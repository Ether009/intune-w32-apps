$ErrorActionPreference = 'Stop'

$TenantId = '46d9804e-e6e3-433c-a5fe-766016144275'
$ClientId = '7a8d6e5a-734c-44ce-8673-3f7c05c47421'
$CertThumbprint = '5ACD0E673C1D5DA72BB2497C37D74A7F67F7AF25'

# This script runs as SYSTEM (the AutoMountTeamSites registry path is writable only by
# SYSTEM/Administrators - a standard user, even the one this script is acting on behalf of,
# cannot write it - confirmed via a real ACL check on a real device). SYSTEM has no "current
# user" of its own, so everything below resolves users explicitly and operates on their
# HKEY_USERS hive rather than relying on $env:LOCALAPPDATA / HKCU / whoami, none of which mean
# anything useful under SYSTEM.

#region Resolve every loaded user hive
function ConvertFrom-EntraSid {
    # An S-1-12-1-* SID *is* the user's Entra object id in disguise: its four sub-authorities are
    # the four little-endian uint32 chunks of the object GUID's 16 bytes. No lookup, no network.
    #
    # Verified end to end against Graph on a real device: S-1-12-1-1241714020-1091069283-
    # 3180256690-539406044 derived to 4a030d64-6563-4108-b2dd-8ebddcae2620, which /users/<guid>
    # resolved to exactly the UPN the OneDrive-registry method produced, and
    # /users/<guid>/memberOf returned the same 13 unified groups that run's log recorded.
    #
    # This matters beyond saving a registry read: the OneDrive-registry method can only identify a
    # user who has already signed in to OneDrive, so a profile that never has was skipped entirely
    # and got no auto-mount entries at all. Deriving from the SID means their libraries can be
    # written before OneDrive's first run rather than after it.
    #
    # Only S-1-12-1-* (Entra) can be derived this way. An S-1-5-21-* SID is a domain or local
    # account whose RID has no relationship to any Entra object, so those still fall back to the
    # OneDrive account lookup.
    param([string]$Sid)
    $parts = $Sid -split '-'
    if ($Sid -notlike 'S-1-12-1-*' -or $parts.Count -ne 8) { return $null }
    try {
        $bytes = New-Object byte[] 16
        for ($i = 0; $i -lt 4; $i++) {
            [Array]::Copy([BitConverter]::GetBytes([uint32]$parts[4 + $i]), 0, $bytes, $i * 4, 4)
        }
        return ([guid]$bytes).ToString()
    } catch { return $null }
}

function Get-LoadedUserContexts {
    # Every user hive currently loaded under HKEY_USERS, not merely "the interactive user". Most of
    # this fleet is shared devices with fast user switching on, so several people are signed in at
    # once; the previous explorer.exe-owner approach silently picked whichever one happened to be
    # first and nobody else was ever synced.
    #
    # This is only safe now that nothing touches a running OneDrive: the entire job is reading and
    # writing registry values under a user's own hive, which needs no session, no desktop, no
    # window station and no token.
    #
    # Deliberately does NOT load signed-off profiles from NTUSER.DAT. A hive that fails to unload
    # stays mounted, which blocks profile deletion and can wedge the User Profile Service at
    # sign-in - comfortably the riskiest thing this tool could do. A signed-off user gets their
    # entries fixed by the logon trigger the moment they sign in, so hive-loading would only make
    # that happen somewhat earlier, which is not worth that failure mode.
    $contexts = @()
    foreach ($key in (Get-ChildItem 'Registry::HKEY_USERS' -ErrorAction SilentlyContinue)) {
        $sid = $key.PSChildName
        # Real user accounts only. S-1-12-1-* is what Entra-joined sign-ins actually get - verified
        # by enumerating HKEY_USERS on a real device, where the signed-in user appeared as
        # S-1-12-1-... and not the S-1-5-21-... form an AD-joined machine would use. The end anchor
        # also excludes the "<sid>_Classes" companion hive, and neither pattern matches .DEFAULT or
        # the S-1-5-18/19/20 service accounts.
        if ($sid -notmatch '^S-1-(12-1|5-21)-[\d-]+$') { continue }
        $profilePath = (Get-ItemProperty -LiteralPath "Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList\$sid" -ErrorAction SilentlyContinue).ProfileImagePath
        if (-not $profilePath) { continue }
        $contexts += [pscustomobject]@{
            Sid           = $sid
            ProfilePath   = $profilePath
            HkuRoot       = "Registry::HKEY_USERS\$sid"
            EntraObjectId = ConvertFrom-EntraSid -Sid $sid
        }
    }
    return $contexts
}
#endregion

# Machine-wide rather than per-user, now that one run covers several users: a single log to read
# when supporting a shared device, and - more useful - a single site cache. A group's site and list
# ids are tenant-global rather than per-user, so everyone in overlapping groups on the same device
# shares the lookups instead of each paying for them.
$StateDir = 'C:\ProgramData\OneDriveTeamSync'
$LogFile = Join-Path $StateDir 'sync.log'
$SiteCacheFile = Join-Path $StateDir 'sitecache.json'
New-Item -ItemType Directory -Path $StateDir -Force | Out-Null

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
function Get-UpnFromOneDriveAccount {
    # whoami /upn only reflects the process's own identity (SYSTEM has none) - read it straight
    # out of the target user's own OneDrive account registration instead, matched by tenant ID
    # in case they have multiple OneDrive accounts configured. This is the same technique the
    # old tool used, which was actually the right call for a SYSTEM-context script - it just
    # wasn't SYSTEM-context before.
    # Returns $null rather than throwing when this hive has no account for our tenant. With every
    # loaded hive now being walked, "this profile has never signed in to OneDrive" is an ordinary
    # thing to encounter (a local admin account, a profile from another tenant), not a failure.
    $accountsPath = "$($UserContext.HkuRoot)\Software\Microsoft\OneDrive\Accounts"
    if (-not (Test-Path $accountsPath)) { return $null }
    foreach ($account in Get-ChildItem $accountsPath -ErrorAction SilentlyContinue) {
        $props = Get-ItemProperty $account.PSPath -ErrorAction SilentlyContinue
        if ($props.ConfiguredTenantId -eq $TenantId -and $props.UserEmail) {
            return $props.UserEmail
        }
    }
    return $null
}

function Get-CurrentUserTeams {
    # Any Microsoft 365 Group the user belongs to, not just ones that have gone through Teams
    # provisioning - the tool was never meant to require that. Filtering on
    # resourceProvisioningOptions -contains 'Team' excluded a real group the user created and
    # was a member of, because Teams-specific provisioning is a separate, sometimes-delayed step
    # from the group (and its SharePoint site) actually existing - groupTypes -contains 'Unified'
    # is what actually distinguishes an M365 Group (has a SharePoint site) from a plain security
    # group (doesn't), independent of whether it's also been made into a Team.
    # $UserId is whichever identifier we have - Graph's /users/{id} accepts the object GUID or the
    # UPN interchangeably, and the GUID is preferred because it can be derived from the SID without
    # the user having ever configured OneDrive.
    param($Token, $UserId)
    $headers = @{ Authorization = "Bearer $Token" }
    $groups = Invoke-RestMethod -Headers $headers -Uri "https://graph.microsoft.com/v1.0/users/$UserId/memberOf?`$select=id,displayName,groupTypes"
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

#region Main sync pass
$contexts = @(Get-LoadedUserContexts)
if ($contexts.Count -eq 0) {
    # No user hives loaded at all - nobody has signed in since boot. The hourly trigger fires
    # whether or not anyone is logged on, so this is an ordinary outcome rather than a failure,
    # and there is nothing worth writing a log line about.
    exit 0
}

try {
    Write-Log "=== Sync run starting ($($contexts.Count) loaded profile(s)) ==="

    # One app-only token covers every user in this run: it is the application's identity, not
    # theirs, so it does not need re-requesting per user. Same for the site cache - a group's site
    # and list ids are tenant-global, so users in overlapping groups share the lookups.
    $token = Get-GraphToken
    $siteCache = Get-SiteCache
    $cacheChanged = $false
    $groupsSeen = @{}
    $usersProcessed = 0

    foreach ($UserContext in $contexts) {
        # Per-user try: on a shared device one user's failure (an expired OneDrive account entry,
        # a Graph hiccup on their /memberOf) must not abandon everyone else in the same run.
        try {
            # The Entra object id derived straight from the SID is preferred: it works for a
            # profile that has never run OneDrive, which the registry lookup cannot see at all.
            # The registry UPN is still read when present, purely so the log names a person
            # rather than a GUID; it is also the fallback identifier on a non-Entra SID.
            $upn = Get-UpnFromOneDriveAccount
            $userId = if ($UserContext.EntraObjectId) { $UserContext.EntraObjectId } else { $upn }
            if (-not $userId) {
                # Neither an Entra SID nor a configured OneDrive account - a local or domain
                # account with no identity we can resolve. Not an error, and not worth a log line
                # on every run for every such profile.
                continue
            }
            $label = if ($upn) { $upn } else { $userId }

            $teams = @(Get-CurrentUserTeams -Token $token -UserId $userId)
            Write-Log "User: $label, Teams: $($teams.Count)"

            # Resolve desired state first - removals have to happen before additions so an entry
            # cleared this run can be rewritten with fresh data below rather than skipped as
            # "already present". Site/list ids come from the shared cache where possible: they are
            # fixed for the life of the group, so re-fetching them every run was two Graph calls
            # per group for data that never changed.
            $desired = @{}
            foreach ($team in $teams) {
                $groupsSeen[$team.id] = $true
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
                if (-not $info) { Write-Log "  Skipping $($team.displayName) - no document library found"; continue }
                $desired[$info.SiteId] = [pscustomobject]@{ Info = $info; DisplayName = $team.displayName }
            }

            # Removals: auto-mount entries this tool previously wrote for sites the user is no
            # longer a member of. Removing the entry is the entire removal story - it is what stops
            # OneDrive being told, every single run, to mount a library the user has lost access to
            # (it retried forever, the error never cleared, and sign-in got measurably slower for
            # each stale library). Nothing is done about the local sync itself: the user removes
            # that themselves, prompted by OneDrive's own "can't sync" error. See git history
            # around v2.2.x for the removed local-disconnect implementation.
            #
            # Only ever touches entries the tool itself created, so it cannot affect the user's
            # personal OneDrive or a library they synced by hand.
            foreach ($entry in @(Get-AutoMountEntries)) {
                if ($desired.ContainsKey($entry.SiteId)) { continue }
                Remove-AutoMountEntry -SiteId $entry.SiteId
            }

            # Additions. Auto-mount state is re-read because the removals above may have cleared an
            # entry we are about to recreate with fresh data.
            #
            # Nothing is done to make OneDrive notice sooner: it re-reads the auto-mount list on its
            # own schedule and picks new entries up within a few hours, confirmed on a real device.
            # Writing the entry is the whole job. An earlier version also zeroed OneDrive's
            # TimerAutoMount cooldown to force an immediate check - that write silently never took
            # effect from SYSTEM, and since the library mounts on its own anyway, it was dropped
            # rather than fixed. Adds only have to converge eventually, not promptly.
            $autoMounted = @(Get-AutoMountEntries)
            foreach ($siteId in $desired.Keys) {
                $info = $desired[$siteId].Info
                if ($autoMounted | Where-Object { $_.SiteId -eq $siteId }) { continue }
                Set-AutoMountEntry -SiteId $info.SiteId -WebId $info.WebId -ListId $info.ListId -WebUrl $info.WebUrl -DisplayName $desired[$siteId].DisplayName
            }

            $usersProcessed++
        }
        catch {
            # Covers a deleted user (Graph 404) as well as anything else that goes wrong for one
            # person. No special case for the 404: a profile belonging to someone removed from the
            # tenant is nothing this tool needs to do anything about, and logging it as an error
            # every run is fine - nobody is coming back to fix a leaver's auto-mount entries.
            Write-Log "ERROR for SID $($UserContext.Sid): $($_.Exception.Message) - continuing with the remaining users."
        }
    }

    # Drop cache entries for groups nobody on this device is in any more, so the file doesn't grow
    # forever and a rejoin re-resolves against Graph rather than trusting arbitrarily old ids.
    # Pruned against the union across all users, not per user - on a shared device one user's
    # groups are not the whole picture, and pruning per user would make them fight over the cache.
    # Skipped entirely if no user was processed successfully, so a total Graph outage empties the
    # cache instead of a run that simply had nothing to say.
    if ($usersProcessed -gt 0) {
        foreach ($cachedId in @($siteCache.Keys)) {
            if (-not $groupsSeen.ContainsKey($cachedId)) { $siteCache.Remove($cachedId); $cacheChanged = $true }
        }
    }
    if ($cacheChanged) { Save-SiteCache -Cache $siteCache }

    Write-Log "=== Sync run complete ($usersProcessed user(s) processed) ==="
}
catch {
    Write-Log "ERROR: $($_.Exception.Message)"
}
#endregion
