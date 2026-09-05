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

# AppUserModelID the toasts are shown under. This MUST be an AUMID Windows already has registered,
# and it is not free-form: an unregistered string makes CreateToastNotifier(...).Show() succeed with
# no error at all while the notification platform silently discards the toast - which is exactly why
# no toast from this script had ever appeared. Verified on a real device: with the old
# 'OneDrive Team Sync' nothing rendered and no key existed under
# HKCU\...\Notifications\Settings, while this one rendered immediately.
#
# Borrowing OneDrive's own identity is deliberate rather than lazy: every toast here is about
# OneDrive needing to be closed or restarted, so "OneDrive" is the honest sender from the user's
# point of view. Registering a distinct AUMID of our own would need a Start Menu shortcut carrying
# the System.AppUserModel.ID property (the registry key alone is not enough for a plain Win32
# process), so if a separate identity is ever wanted, that shortcut has to be installed and tested
# first - do not simply change this string and assume it works.
$ToastAppId = 'Microsoft.SkyDrive.Desktop'

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

    [DllImport("advapi32.dll", SetLastError = true)]
    static extern bool OpenProcessToken(IntPtr ProcessHandle, uint DesiredAccess, out IntPtr TokenHandle);

    [DllImport("advapi32.dll", SetLastError = true)]
    static extern bool LookupPrivilegeValue(string lpSystemName, string lpName, out LUID lpLuid);

    [DllImport("advapi32.dll", SetLastError = true)]
    static extern bool AdjustTokenPrivileges(IntPtr TokenHandle, bool DisableAllPrivileges,
        ref TOKEN_PRIVILEGES NewState, uint BufferLengthInBytes, IntPtr PreviousState, IntPtr ReturnLengthInBytes);

    [DllImport("kernel32.dll")]
    static extern IntPtr GetCurrentProcess();

    [StructLayout(LayoutKind.Sequential)]
    struct LUID { public uint LowPart; public int HighPart; }

    [StructLayout(LayoutKind.Sequential)]
    struct TOKEN_PRIVILEGES { public uint PrivilegeCount; public LUID Luid; public uint Attributes; }

    // WTSQueryUserToken requires SeTcbPrivilege to be actively enabled on the calling token, not
    // merely present - confirmed for real that a SYSTEM token launched via a raw PsExec -s child
    // has it present but disabled, which makes WTSQueryUserToken fail silently (a real Scheduled
    // Task launch of this same script may or may not already have it enabled depending on how
    // it's invoked, so enabling it explicitly here removes the ambiguity rather than relying on
    // the launch method to have gotten it right).
    public static void EnableTcbPrivilege()
    {
        IntPtr hToken;
        if (!OpenProcessToken(GetCurrentProcess(), 0x0020 /* TOKEN_ADJUST_PRIVILEGES */ | 0x0008 /* TOKEN_QUERY */, out hToken))
            throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error(), "OpenProcessToken failed");
        try
        {
            LUID luid;
            if (!LookupPrivilegeValue(null, "SeTcbPrivilege", out luid))
                throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error(), "LookupPrivilegeValue(SeTcbPrivilege) failed");
            var tp = new TOKEN_PRIVILEGES { PrivilegeCount = 1, Luid = luid, Attributes = 0x00000002 /* SE_PRIVILEGE_ENABLED */ };
            if (!AdjustTokenPrivileges(hToken, false, ref tp, 0, IntPtr.Zero, IntPtr.Zero))
                throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error(), "AdjustTokenPrivileges(SeTcbPrivilege) failed");
        }
        finally { CloseHandle(hToken); }
    }

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

    public static int Start(uint sessionId, string commandLine)
    {
        // Every failure below throws with GetLastError rather than returning bool - a prior
        // version swallowed all of this via "| Out-Null" on the PowerShell side, which let a
        // silently-failed OneDrive /shutdown look identical to a successful one until the code
        // that waited for the process to actually exit timed out with no clue why.
        IntPtr userToken;
        if (!WTSQueryUserToken(sessionId, out userToken))
            throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error(), "WTSQueryUserToken failed for session " + sessionId);

        IntPtr dupToken;
        // SecurityImpersonation = 2, TokenPrimary = 1, TOKEN_ALL_ACCESS-ish via 0xF01FF
        if (!DuplicateTokenEx(userToken, 0xF01FF, IntPtr.Zero, 2, 1, out dupToken))
        {
            int err = Marshal.GetLastWin32Error();
            CloseHandle(userToken);
            throw new System.ComponentModel.Win32Exception(err, "DuplicateTokenEx failed");
        }

        IntPtr env;
        if (!CreateEnvironmentBlock(out env, dupToken, false))
        {
            // Not fatal on its own, but worth being loud about: with a null block the new process
            // inherits SYSTEM's environment, so %LOCALAPPDATA% and friends point at
            // config\systemprofile instead of the user's profile.
            env = IntPtr.Zero;
        }

        var si = new STARTUPINFO();
        si.cb = Marshal.SizeOf(typeof(STARTUPINFO));
        // MUST be the empty string, not "winsta0\\default" and not null. Measured on a real
        // machine: with "winsta0\\default" every launch - OneDrive, notepad, anything - was
        // created successfully (CreateProcessAsUser returns TRUE with a real PID) and was then
        // killed during startup with exit code 0xC0000142 STATUS_DLL_INIT_FAILED, because a
        // session-0 caller has that name resolved against session 0's window station, which the
        // user's session token cannot attach to, so user32's DllMain fails before Main runs. That
        // is the whole reason "restart OneDrive" used to report success while leaving OneDrive
        // stopped. null behaved the same way but intermittently; "" is the documented way to say
        // "give me the default desktop of the token's own session" and was the only value that
        // worked every time.
        si.lpDesktop = "";

        PROCESS_INFORMATION pi;
        // CREATE_UNICODE_ENVIRONMENT (0x400) | CREATE_NO_WINDOW (0x08000000). The 0x400 is not
        // optional while an environment block is passed - without it CreateProcessAsUser rejects
        // the Unicode block with ERROR_INVALID_PARAMETER (87).
        //
        // lpCurrentDirectory must also be a real, explicitly named directory. Passing null makes
        // the child inherit the *caller's* current directory, which is then resolved against the
        // *user's* token; when SYSTEM's working directory is not something that user can resolve,
        // CreateProcessAsUser fails outright with ERROR_INVALID_NAME (123) before the image is
        // ever loaded. The Windows directory is always present and always readable.
        string workingDir = Environment.GetEnvironmentVariable("SystemRoot");
        if (string.IsNullOrEmpty(workingDir)) workingDir = "C:\\Windows";

        bool ok = CreateProcessAsUser(dupToken, null, commandLine, IntPtr.Zero, IntPtr.Zero, false,
            0x08000400, env, workingDir, ref si, out pi);
        int createErr = ok ? 0 : Marshal.GetLastWin32Error();
        int newPid = ok ? pi.dwProcessId : 0;

        if (env != IntPtr.Zero) DestroyEnvironmentBlock(env);
        CloseHandle(dupToken);
        CloseHandle(userToken);
        if (ok) { CloseHandle(pi.hProcess); CloseHandle(pi.hThread); }
        if (!ok) throw new System.ComponentModel.Win32Exception(createErr, "CreateProcessAsUser failed for: " + commandLine);
        return newPid;
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
    # Logs the PID rather than returning it, so callers stay side-effect free. The PID matters:
    # a process that is created and then dies during startup looks exactly like a process that
    # was never created unless you can go back and ask what happened to that specific PID.
    param([Parameter(Mandatory)][uint32]$SessionId, [Parameter(Mandatory)][string]$CommandLine)
    $newPid = [RunAsUser]::Start($SessionId, $CommandLine)
    Write-Log "Launched PID $newPid in session ${SessionId}: $CommandLine"
}
#endregion

[RunAsUser]::EnableTcbPrivilege()
$UserContext = Get-InteractiveUserContext
$LogDir = Join-Path $UserContext.LocalAppData 'OneDriveTeamSync'
$LogFile = Join-Path $LogDir 'sync.log'
$DecisionsFile = Join-Path $LogDir 'decisions.json'
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

#region Local JSON state (decisions, site-info cache, pending-disconnect bookkeeping)
function Read-JsonHashtable {
    # ConvertFrom-Json -AsHashtable is PowerShell 6+ only, and this runs under Windows PowerShell
    # 5.1 - the previous code used it inside a try/catch that swallowed the resulting error, so
    # every read silently returned an empty hashtable and no decision was ever actually remembered.
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

function Get-Decisions { Read-JsonHashtable -Path $DecisionsFile }

function Set-Decision {
    param([string]$SiteId, [string]$Decision)
    $decisions = Get-Decisions
    $decisions[$SiteId] = @{ decision = $Decision; timestamp = (Get-Date -Format 'o') }
    Write-JsonHashtable -Path $DecisionsFile -Value $decisions
}

# A group's SharePoint site and document-library ids never change once provisioned, but resolving
# them costs two Graph calls per group on every single run - by far the bulk of this script's Graph
# traffic (1 + 2N calls for N groups). Caching them locally reduces a steady-state run to just the
# token request plus the one /memberOf call that genuinely has to be fresh, which is what makes
# running this on a repeating schedule rather than only at logon reasonable.
function Get-SiteCache { Read-JsonHashtable -Path $SiteCacheFile }
function Save-SiteCache { param($Cache) Write-JsonHashtable -Path $SiteCacheFile -Value $Cache }

#endregion

#region Toast notification with Approve/Reject buttons, shown inside the user's own session
# (a toast raised directly from SYSTEM would never reach their desktop at all) via the
# odteamsync:// protocol handler routing the button click back into this same script.
function ConvertTo-XmlText {
    # Library and group names here are real user-facing names and can legitimately contain & or
    # quotes, which would otherwise produce malformed toast XML and no notification at all.
    param([string]$Text)
    return [System.Security.SecurityElement]::Escape($Text)
}

function Show-Toast {
    param([string]$ToastXml)

    $toastScript = @"
[Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime] | Out-Null
[Windows.Data.Xml.Dom.XmlDocument, Windows.Data.Xml.Dom.XmlDocument, ContentType = WindowsRuntime] | Out-Null
`$xml = [xml]@'
$ToastXml
'@
`$toastXml = New-Object Windows.Data.Xml.Dom.XmlDocument
`$toastXml.LoadXml(`$xml.OuterXml)
`$toast = New-Object Windows.UI.Notifications.ToastNotification `$toastXml
[Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier('$ToastAppId').Show(`$toast)
"@
    $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($toastScript))
    Start-ProcessInUserSession -SessionId $UserContext.SessionId -CommandLine "powershell.exe -NoProfile -WindowStyle Hidden -EncodedCommand $encoded"
}

function Show-ConflictToast {
    param([string]$TeamName, [string]$SiteId)
    $safeName = ConvertTo-XmlText $TeamName
    Show-Toast -ToastXml @"
<toast>
  <visual>
    <binding template="ToastGeneric">
      <text>OneDrive: sync conflict</text>
      <text>"$safeName" already has a specific channel synced. Replace it with the full Team library instead?</text>
    </binding>
  </visual>
  <actions>
    <action content="Yes, replace it" arguments="odteamsync://approve/$SiteId" activationType="protocol" />
    <action content="No, leave as is" arguments="odteamsync://reject/$SiteId" activationType="protocol" />
  </actions>
</toast>
"@
}

#endregion

#region OneDrive registry state - actual live syncs (under the target user's own hive, not HKCU)
function Get-SyncedLibraries {
    $root = "$($UserContext.HkuRoot)\Software\SyncEngines\Providers\OneDrive"
    if (-not (Test-Path $root)) { return @() }
    Get-ChildItem $root | ForEach-Object {
        $props = Get-ItemProperty $_.PSPath
        # UrlNamespace is a plain URL with no embedded ids in real data ("https://tenant.sharepoint.com
        # /sites/xxx/Delade dokument/") - SiteId/WebId/ListId below are left null and resolved
        # left unresolved: nothing downstream needs them any more now that removal is limited to
        # deleting the auto-mount entry, which is matched by the SiteId this tool itself wrote.
        [pscustomobject]@{
            RegistryKey  = $_.PSPath
            SyncId       = $_.PSChildName
            MountPoint   = $props.MountPoint
            UrlNamespace = $props.UrlNamespace
            SiteId       = $null
            WebId        = $null
            ListId       = $null
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
            # Stashed for Remove-OneDriveDeepSyncState below - avoids re-deriving which
            # Accounts sub-key belongs to this tenant a second time.
            $script:OneDriveAccountName = $account.PSChildName
            $script:OneDriveOneAuthAccountId = $props.OneAuthAccountId
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
    # The protocol handler hands us the whole URL ("odteamsync://approve/<siteId>"), so the scheme
    # has to come off first - splitting the raw string on "/" put "odteamsync:" in the action slot
    # and silently matched nothing at all, which is why no toast button has ever done anything.
    $parts = ($ToastCallback -replace '^\s*odteamsync:/*', '').TrimEnd('/') -split '/'
    $action = $parts[0]
    $siteId = if ($parts.Count -gt 1) { $parts[1] } else { $null }

    switch ($action) {
        'approve' {
            Set-Decision -SiteId $siteId -Decision 'approved'
            Write-Log "Decision recorded - will be applied on the next sync run."
        }
        'reject' {
            Set-Decision -SiteId $siteId -Decision 'rejected'
            Write-Log "Decision recorded - will be applied on the next sync run."
        }
        default { Write-Log "Unrecognized toast callback action: $action" }
    }
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
    # either a toast button (which never renders - see the note on Show-ConflictToast) or on the
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

    # Channel-vs-team conflicts: a channel-specific folder already synced for a site where we
    # actually want the main library instead.
    # Pre-existing limitation: $_.SiteId/.ListId on $synced entries are unresolved (UrlNamespace
    # carries no ids of its own - see Get-SyncedLibraries), so $existingForSite below never actually
    # matches anything and this conflict detection is currently inert. It has never worked in
    # production; fixing it is a separate task. Note also that its toast asks a question with
    # buttons that never render (see Show-ConflictToast), so making detection work is necessary but
    # not sufficient - that flow needs a different way to ask.
    #
    # .Keys is copied with @() because the loop removes from $desired as it goes; enumerating a
    # hashtable's live key collection while mutating it throws. Latent rather than observed, since
    # the loop body is currently unreachable for the reason above.
    foreach ($siteId in @($desired.Keys)) {
        $info = $desired[$siteId].Info
        $existingForSite = $synced | Where-Object { $_.SiteId -eq $siteId }
        $mainAlreadySynced = $existingForSite | Where-Object { $_.ListId -eq $info.ListId }
        if ($mainAlreadySynced) { continue }

        $channelSynced = $existingForSite | Where-Object { $_.ListId -ne $info.ListId }
        if ($channelSynced) {
            $decision = $decisions[$siteId]
            if ($decision -and $decision.decision -eq 'approved') {
                # The main library is still added below. The channel folder it was meant to replace
                # can no longer be removed for them, so say so rather than silently leaving two
                # near-identical folders behind with no explanation.
                foreach ($c in $channelSynced) {
                    Write-Log "Approved channel->team swap for $($desired[$siteId].DisplayName) - the old channel folder must be disconnected manually: $($c.MountPoint)"
                }
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

    #region Additions
    # Re-read auto-mount state in case the removals pass above cleared an entry we're about to
    # recreate below with fresh data (e.g. a resolved channel/team conflict).
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
