[CmdletBinding()]
param(
    # Set by the registered odteamsync:// protocol handler when a toast notification button is
    # clicked. Format: "approve/<siteId>" or "reject/<siteId>". Not used on a normal login run.
    [string]$ToastCallback
)

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
# Native P/Invoke to launch a process inside another user's session - required because SYSTEM
# cannot interact with a user's desktop directly (restarting OneDrive so it releases file
# handles, and showing a toast notification, both need to happen IN that user's session).
$runAsUserSource = @'
using System;
using System.Runtime.InteropServices;

public static class RunAsUser
{
    [DllImport("wtsapi32.dll", SetLastError = true)]
    static extern bool WTSQueryUserToken(uint sessionId, out IntPtr token);

    [DllImport("advapi32.dll", SetLastError = true)]
    static extern bool DuplicateTokenEx(IntPtr hExistingToken, uint dwDesiredAccess, IntPtr lpTokenAttributes,
        int impersonationLevel, int tokenType, out IntPtr phNewToken);

    [DllImport("userenv.dll", SetLastError = true)]
    static extern bool CreateEnvironmentBlock(out IntPtr lpEnvironment, IntPtr hToken, bool bInherit);

    [DllImport("userenv.dll", SetLastError = true)]
    static extern bool DestroyEnvironmentBlock(IntPtr lpEnvironment);

    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool CloseHandle(IntPtr hObject);

    [StructLayout(LayoutKind.Sequential)]
    struct STARTUPINFO
    {
        public int cb; public string lpReserved; public string lpDesktop; public string lpTitle;
        public int dwX; public int dwY; public int dwXSize; public int dwYSize;
        public int dwXCountChars; public int dwYCountChars; public int dwFillAttribute; public int dwFlags;
        public short wShowWindow; public short cbReserved2; public IntPtr lpReserved2;
        public IntPtr hStdInput; public IntPtr hStdOutput; public IntPtr hStdError;
    }

    [StructLayout(LayoutKind.Sequential)]
    struct PROCESS_INFORMATION
    {
        public IntPtr hProcess; public IntPtr hThread; public int dwProcessId; public int dwThreadId;
    }

    [DllImport("advapi32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    static extern bool CreateProcessAsUser(IntPtr hToken, string lpApplicationName, string lpCommandLine,
        IntPtr lpProcessAttributes, IntPtr lpThreadAttributes, bool bInheritHandles, uint dwCreationFlags,
        IntPtr lpEnvironment, string lpCurrentDirectory, ref STARTUPINFO lpStartupInfo,
        out PROCESS_INFORMATION lpProcessInformation);

    public static bool Start(uint sessionId, string commandLine)
    {
        IntPtr userToken;
        if (!WTSQueryUserToken(sessionId, out userToken)) return false;

        IntPtr dupToken;
        // SecurityImpersonation = 2, TokenPrimary = 1, TOKEN_ALL_ACCESS-ish via 0xF01FF
        if (!DuplicateTokenEx(userToken, 0xF01FF, IntPtr.Zero, 2, 1, out dupToken))
        {
            CloseHandle(userToken);
            return false;
        }

        IntPtr env;
        CreateEnvironmentBlock(out env, dupToken, false);

        var si = new STARTUPINFO();
        si.cb = Marshal.SizeOf(typeof(STARTUPINFO));
        si.lpDesktop = "winsta0\\default";

        PROCESS_INFORMATION pi;
        // CREATE_UNICODE_ENVIRONMENT (0x400) | CREATE_NO_WINDOW (0x08000000)
        bool ok = CreateProcessAsUser(dupToken, null, commandLine, IntPtr.Zero, IntPtr.Zero, false,
            0x08000400, env, null, ref si, out pi);

        if (env != IntPtr.Zero) DestroyEnvironmentBlock(env);
        CloseHandle(dupToken);
        CloseHandle(userToken);
        if (ok) { CloseHandle(pi.hProcess); CloseHandle(pi.hThread); }
        return ok;
    }
}
'@
Add-Type -TypeDefinition $runAsUserSource -ErrorAction SilentlyContinue

function Get-InteractiveUserContext {
    # explorer.exe only runs in an interactive user's own session, never SYSTEM's or a service
    # session - its owner and session ID reliably identify "the person actually sitting here."
    $proc = Get-CimInstance Win32_Process -Filter "Name='explorer.exe'" | Select-Object -First 1
    if (-not $proc) { throw "No interactive user session found (explorer.exe not running)." }
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

function Start-ProcessInUserSession {
    param([Parameter(Mandatory)][uint32]$SessionId, [Parameter(Mandatory)][string]$CommandLine)
    [RunAsUser]::Start($SessionId, $CommandLine) | Out-Null
}
#endregion

$UserContext = Get-InteractiveUserContext
$LogDir = Join-Path $UserContext.LocalAppData 'OneDriveTeamSync'
$LogFile = Join-Path $LogDir 'sync.log'
$DecisionsFile = Join-Path $LogDir 'decisions.json'
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

#region Decision persistence (remembers a rejected channel->team swap so we don't re-prompt)
function Get-Decisions {
    if (Test-Path $DecisionsFile) {
        try { return Get-Content $DecisionsFile -Raw | ConvertFrom-Json -AsHashtable } catch { return @{} }
    }
    return @{}
}
function Set-Decision {
    param([string]$SiteId, [string]$Decision)
    $decisions = Get-Decisions
    $decisions[$SiteId] = @{ decision = $Decision; timestamp = (Get-Date -Format 'o') }
    $decisions | ConvertTo-Json | Out-File -FilePath $DecisionsFile -Encoding UTF8
}
#endregion

#region Toast notification with Approve/Reject buttons, shown inside the user's own session
# (a toast raised directly from SYSTEM would never reach their desktop at all) via the
# odteamsync:// protocol handler routing the button click back into this same script.
function Show-ConflictToast {
    param([string]$TeamName, [string]$SiteId)

    $toastScript = @"
[Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime] | Out-Null
[Windows.Data.Xml.Dom.XmlDocument, Windows.Data.Xml.Dom.XmlDocument, ContentType = WindowsRuntime] | Out-Null
`$xml = [xml]@'
<toast>
  <visual>
    <binding template="ToastGeneric">
      <text>OneDrive: sync conflict</text>
      <text>"$TeamName" already has a specific channel synced. Replace it with the full Team library instead?</text>
    </binding>
  </visual>
  <actions>
    <action content="Yes, replace it" arguments="odteamsync://approve/$SiteId" activationType="protocol" />
    <action content="No, leave as is" arguments="odteamsync://reject/$SiteId" activationType="protocol" />
  </actions>
</toast>
'@
`$toastXml = New-Object Windows.Data.Xml.Dom.XmlDocument
`$toastXml.LoadXml(`$xml.OuterXml)
`$toast = New-Object Windows.UI.Notifications.ToastNotification `$toastXml
[Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier('OneDrive Team Sync').Show(`$toast)
"@
    $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($toastScript))
    Start-ProcessInUserSession -SessionId $UserContext.SessionId -CommandLine "powershell.exe -NoProfile -WindowStyle Hidden -EncodedCommand $encoded"
}
#endregion

#region OneDrive registry state - actual live syncs (under the target user's own hive, not HKCU)
function Get-SyncedLibraries {
    $root = "$($UserContext.HkuRoot)\Software\SyncEngines\Providers\OneDrive"
    if (-not (Test-Path $root)) { return @() }
    Get-ChildItem $root | ForEach-Object {
        $props = Get-ItemProperty $_.PSPath
        if ($props.UrlNamespace -match ';\{([0-9a-fA-F-]+)\};\{([0-9a-fA-F-]+)\};\{([0-9a-fA-F-]+)\}') {
            [pscustomobject]@{
                RegistryKey = $_.PSPath
                MountPoint  = $props.MountPoint
                UrlNamespace = $props.UrlNamespace
                SiteId      = $Matches[1]
                WebId       = $Matches[2]
                ListId      = $Matches[3]
            }
        }
    }
}

function Disconnect-SyncedLibrary {
    # Registry-only: tells OneDrive's sync engine to stop tracking this library. Deliberately
    # does NOT touch the local folder - deleting local files before OneDrive has actually
    # released the folder risks OneDrive's file-system watcher seeing files "disappear" from a
    # path it still believes is live, and syncing that deletion up to SharePoint itself. This
    # happened for real during testing: a folder was deleted immediately after the registry key,
    # with no restart/settle time in between, and the files were deleted online too (recovered
    # from the SharePoint recycle bin, but it was a real production incident). Local folder
    # deletion now only happens in the main pass, after OneDrive has been restarted and given
    # real time to settle - see Wait-ForOneDriveToSettle / Remove-StaleLocalFolders below.
    param($Library)
    Write-Log "Disconnecting sync: $($Library.UrlNamespace)"
    Remove-Item -Path $Library.RegistryKey -Recurse -Force -ErrorAction SilentlyContinue
}

function Get-OneDriveExePath {
    # OneDrive can be installed per-machine (Program Files) or per-user (LocalAppData) depending
    # on how it was deployed - confirmed for real that this fleet uses the per-machine install,
    # not the per-user one this originally assumed. Check both rather than hardcode either.
    $candidates = @(
        'C:\Program Files\Microsoft OneDrive\OneDrive.exe',
        (Join-Path $UserContext.LocalAppData 'Microsoft\OneDrive\OneDrive.exe')
    )
    $found = $candidates | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
    if (-not $found) { throw "Could not locate OneDrive.exe in any known install location." }
    return $found
}

function Wait-ForOneDriveToSettle {
    Write-Log "Restarting OneDrive (in-session) and waiting for it to settle before touching local folders."
    Get-Process -Name OneDrive -ErrorAction SilentlyContinue | Where-Object { $_.SessionId -eq $UserContext.SessionId } | Stop-Process -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 5
    $exePath = Get-OneDriveExePath
    Start-ProcessInUserSession -SessionId $UserContext.SessionId -CommandLine "`"$exePath`" /background"
    # A restarted OneDrive process existing isn't the same as it having actually finished
    # reloading the sync engine and releasing file handles on the folders we just disconnected -
    # there's no reliable API to ask "are you done." Give it a generous, fixed settle window
    # rather than racing it, given what a wrong guess here already cost once.
    Start-Sleep -Seconds 60
}

function Remove-StaleLocalFolders {
    param($Libraries)
    foreach ($lib in $Libraries) {
        if ($lib.MountPoint -and (Test-Path $lib.MountPoint)) {
            Write-Log "Deleting local folder (post-settle): $($lib.MountPoint)"
            Remove-Item -Path $lib.MountPoint -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}
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
# replaces the add path; removal still goes through Disconnect-SyncedLibrary above.
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
    param($Token, $Upn)
    $headers = @{ Authorization = "Bearer $Token" }
    $groups = Invoke-RestMethod -Headers $headers -Uri "https://graph.microsoft.com/v1.0/users/$Upn/memberOf?`$select=id,displayName,resourceProvisioningOptions"
    return $groups.value | Where-Object { $_.resourceProvisioningOptions -contains 'Team' }
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

#region Toast callback handling (protocol handler re-invokes this script with -ToastCallback)
# Clicking a toast button re-invokes this script AS THE USER who clicked it (that's their own
# session, not SYSTEM), unlike the normal logon-triggered run. Rather than have two different
# security contexts both needing to authenticate to Graph, just record the decision here (a
# plain per-user JSON file, no elevated access needed) and stop - the next SYSTEM-context logon
# run picks up the decision and acts on it. That means an approval takes effect at the user's
# next login rather than instantly, which is an acceptable tradeoff for not needing the
# certificate's private key to be readable outside SYSTEM/Administrators at all.
if ($ToastCallback) {
    Write-Log "Toast callback received: $ToastCallback"
    $parts = $ToastCallback -split '/'
    $action = $parts[0]
    $siteId = $parts[1]

    if ($action -eq 'approve') {
        Set-Decision -SiteId $siteId -Decision 'approved'
    } elseif ($action -eq 'reject') {
        Set-Decision -SiteId $siteId -Decision 'rejected'
    }
    Write-Log "Decision recorded - will be applied on the next login sync run."
    exit 0
}
#endregion

#region Main sync pass
try {
    Write-Log "=== Sync run starting ==="
    $token = Get-GraphToken
    $upn = Get-CurrentUserUpn
    $teams = @(Get-CurrentUserTeams -Token $token -Upn $upn)
    Write-Log "User: $upn, Teams: $($teams.Count)"

    $synced = @(Get-SyncedLibraries)
    $autoMounted = @(Get-AutoMountEntries)
    $decisions = Get-Decisions

    # Resolve desired state first - removals have to happen before additions so a channel/team
    # conflict on the same site is actually clear by the time we try to add the replacement.
    $desired = @{}
    foreach ($team in $teams) {
        $info = Get-TeamSiteInfo -Token $token -GroupId $team.id
        if (-not $info) { Write-Log "Skipping $($team.displayName) - no document library found"; continue }
        $desired[$info.SiteId] = [pscustomobject]@{ Info = $info; DisplayName = $team.displayName }
    }

    #region Removals
    # Libraries to disconnect this run - local folder deletion is deferred until after OneDrive
    # has been restarted and given real time to settle (see Wait-ForOneDriveToSettle below).
    $toDisconnect = @()

    # Actually-synced libraries for sites the user is no longer a Team member of.
    foreach ($lib in $synced) {
        if (-not $desired.ContainsKey($lib.SiteId)) {
            Disconnect-SyncedLibrary -Library $lib
            $toDisconnect += $lib
        }
    }

    # Auto-mount entries we previously set for sites no longer desired - doesn't retroactively
    # unsync anything already synced, but keeps our own authored list accurate.
    foreach ($entry in $autoMounted) {
        if (-not $desired.ContainsKey($entry.SiteId)) {
            Remove-AutoMountEntry -SiteId $entry.SiteId
        }
    }

    # Channel-vs-team conflicts: a channel-specific folder already synced for a site where we
    # actually want the main library instead. Resolve (or prompt for) these before the additions
    # pass below, per an approved swap.
    foreach ($siteId in $desired.Keys) {
        $info = $desired[$siteId].Info
        $existingForSite = $synced | Where-Object { $_.SiteId -eq $siteId }
        $mainAlreadySynced = $existingForSite | Where-Object { $_.ListId -eq $info.ListId }
        if ($mainAlreadySynced) { continue }

        $channelSynced = $existingForSite | Where-Object { $_.ListId -ne $info.ListId }
        if ($channelSynced) {
            $decision = $decisions[$siteId]
            if ($decision -and $decision.decision -eq 'approved') {
                foreach ($c in $channelSynced) { Disconnect-SyncedLibrary -Library $c; $toDisconnect += $c }
            } elseif ($decision -and $decision.decision -eq 'rejected') {
                Write-Log "Skipping $($desired[$siteId].DisplayName) - user previously rejected the channel->team swap"
                $desired.Remove($siteId)
            } else {
                Write-Log "Conflict detected for $($desired[$siteId].DisplayName) - prompting"
                Show-ConflictToast -TeamName $desired[$siteId].DisplayName -SiteId $siteId
                $desired.Remove($siteId)
            }
        }
    }
    #endregion

    if ($toDisconnect.Count -gt 0) {
        Wait-ForOneDriveToSettle
        Remove-StaleLocalFolders -Libraries $toDisconnect
    }

    #region Additions
    # Re-read auto-mount state in case the removals pass above cleared an entry we're about to
    # recreate below with fresh data (e.g. a resolved channel/team conflict).
    $autoMounted = @(Get-AutoMountEntries)
    foreach ($siteId in $desired.Keys) {
        $info = $desired[$siteId].Info
        $existing = $autoMounted | Where-Object { $_.SiteId -eq $siteId }
        $alreadySynced = ($synced | Where-Object { $_.SiteId -eq $siteId -and $_.ListId -eq $info.ListId })
        if ($existing -or $alreadySynced) { continue }
        Set-AutoMountEntry -SiteId $info.SiteId -WebId $info.WebId -ListId $info.ListId -WebUrl $info.WebUrl -DisplayName $desired[$siteId].DisplayName
    }
    #endregion

    Write-Log "=== Sync run complete ==="
}
catch {
    Write-Log "ERROR: $($_.Exception.Message)"
}
#endregion
